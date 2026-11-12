import Foundation
import os

/// The live usage provider. Mirrors SpaceTerm's `claude-usage.ts`:
///   • read the OAuth token from the login Keychain item "Claude Code-credentials"
///     (account = $USER) by shelling out to `security` (avoids Keychain-entitlement
///     fuss; the item's ACL trusts /usr/bin/security);
///   • GET https://api.anthropic.com/api/oauth/usage with the OAuth bearer token.
///
/// Each reading is tagged with the account the token belongs to (see `account(for:)`), so
/// switching between, say, a personal plan and a Team seat keeps each one's windows apart.
///
/// Cadence: the caller must not fetch more than once per 5 minutes.
final class ClaudeUsageFetcher: UsageProvider, @unchecked Sendable {
    let id: ProviderID = .claude
    /// Never faster than once per 5 minutes (Anthropic usage endpoint).
    let suggestedInterval: TimeInterval = 5 * 60

    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let userAgent = "claude-code/2.1.47"
    private static let timeout: TimeInterval = 5

    /// No OAuth credentials found — either an API-key account (no Claude.ai
    /// subscription) or the credential item read as absent while Claude Code was
    /// rewriting it. Reported to the user; the poller retries next cooldown.
    struct NoOAuthCredentialsError: Error {}
    /// `security` failed for another reason (keychain locked, prompt dismissed,
    /// etc.). `detail` carries the tool's stderr.
    struct KeychainError: Error { let detail: String }
    /// The profile response named no organization to attribute the reading to.
    struct UnknownAccountError: Error {}
    /// The usage or profile endpoint returned a non-2xx status.
    struct UsageAPIError: Error, RawResponseCarrying {
        let status: Int
        let body: String

        /// The raw response for "copy last response": the status plus the body.
        var rawResponse: String { "HTTP \(status)\n\(body)" }

        /// A concise, user-facing line: prefers the API's `error.message`, else a
        /// trimmed one-line snippet of the body.
        var userMessage: String {
            let snippet = Self.snippet(from: body)
            return snippet.isEmpty ? "Usage API returned \(status)" : "Usage API \(status): \(snippet)"
        }

        private static func snippet(from body: String) -> String {
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String { return message }
            let oneLine = body.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(oneLine.prefix(120))
        }
    }

    /// The account behind the most recent token, so the profile is looked up once per
    /// login rather than once per fetch. Locked because "Refresh Now" can overlap a
    /// scheduled fetch.
    private let cachedAccount = OSAllocatedUnfairLock<(token: String, account: AccountRef)?>(initialState: nil)

    func fetch() async throws -> FetchResult {
        let token = try Self.readAccessToken()
        let account = try await account(for: token)
        let (data, raw) = try await Self.get(Self.usageURL, token: token)
        var snapshot: ProviderSnapshot
        do {
            snapshot = try Self.decode(data)
        } catch {
            throw ResponseParseError(rawResponse: raw, underlying: error)
        }
        snapshot.account = account
        return FetchResult(snapshot: snapshot, raw: raw)
    }

    /// The account `token` belongs to, asked of the API with that same token. Deriving it
    /// from the token is what makes the attribution trustworthy: Claude Code's
    /// `~/.claude.json` names an account too, but it can lag the Keychain by minutes after
    /// a `/login`, and other running sessions can write their stale copy back over it.
    private func account(for token: String) async throws -> AccountRef {
        if let cached = cachedAccount.withLock({ $0 }), cached.token == token { return cached.account }
        let (data, raw) = try await Self.get(Self.profileURL, token: token)
        guard let account = Self.parseAccount(fromProfile: data) else {
            throw ResponseParseError(rawResponse: raw, underlying: UnknownAccountError())
        }
        cachedAccount.withLock { $0 = (token, account) }
        return account
    }

    /// GET an OAuth endpoint, returning the body of a 2xx response.
    private static func get(_ url: URL, token: String) async throws -> (data: Data, raw: String) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: req)
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageAPIError(status: http.statusCode, body: raw)
        }
        return (data, raw)
    }

    func classify(_ error: Error) -> String {
        switch error {
        case let e as ResponseParseError:
            return classify(e.underlying)
        case is NoOAuthCredentialsError:
            return "No Claude subscription credentials in Keychain (API-key account?)"
        case let e as KeychainError:
            return "Keychain read failed: \(e.detail)"
        case is UnknownAccountError:
            return "Couldn't tell which Claude account is signed in"
        case let e as UsageAPIError:
            return e.userMessage
        case let e as URLError:
            return "Network error: \(e.localizedDescription)"
        case is DecodingError:
            return "Couldn't parse the usage response"
        default:
            return "Fetch failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Keychain

    /// Read the `claudeAiOauth.accessToken` from the Keychain via `security`. Maps
    /// the shared Keychain errors onto this provider's own taxonomy.
    private static func readAccessToken() throws -> String {
        let raw: String
        do {
            raw = try Keychain.readGenericPassword(service: keychainService, account: NSUserName())
        } catch is Keychain.ItemNotFound {
            throw NoOAuthCredentialsError()
        } catch let e as Keychain.AccessError {
            throw KeychainError(detail: e.detail)
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw NoOAuthCredentialsError()
        }
        return token
    }

    // MARK: - Account

    /// The account is keyed by organization: a personal plan and a Team seat share one
    /// user (same email, same account UUID) but are separate organizations with separate
    /// rate limits. A personal plan's organization is auto-named "<email>'s Organization",
    /// which is labeled by the email's domain ("@example.com") to tell personal plans
    /// apart; any other organization goes by its name.
    static func parseAccount(fromProfile data: Data) -> AccountRef? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let org = json["organization"] as? [String: Any],
              let orgID = org["uuid"] as? String, !orgID.isEmpty else { return nil }
        let name = (org["name"] as? String) ?? ""
        guard name.isEmpty || name.hasSuffix("'s Organization") else {
            return AccountRef(id: orgID, label: name)
        }
        let email = (json["account"] as? [String: Any])?["email"] as? String
        return AccountRef(id: orgID, label: emailDomainLabel(email) ?? "Personal")
    }

    /// "someone@example.com" → "@example.com", or nil if there's no domain to show.
    private static func emailDomainLabel(_ email: String?) -> String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...]
        return domain.isEmpty ? nil : "@\(domain)"
    }

    // MARK: - Decode

    /// The window pies are driven by the JSON `limits` array: each entry the server
    /// sends becomes one pie, so windows appear and disappear exactly as reported —
    /// including per-model scoped windows like "Fable 7-Day". We only recognize the
    /// window `group`s we know how to size (`session` → 5-hour, `weekly` → 7-day);
    /// an unrecognized group is skipped rather than guessed at. `percent`/`resets_at`
    /// come back `null` for an idle window, which reads as 0% usage / 0% time (it
    /// starts when first used), never "no data".
    ///
    /// Older responses without a `limits` array fall back to the legacy top-level
    /// `five_hour`/`seven_day` buckets so the two core windows still render. Spend
    /// still comes from `extra_usage` (the payload also carries seven_day_opus,
    /// spend, … which we don't chart).
    static func decode(_ data: Data) throws -> ProviderSnapshot {
        struct Bucket: Decodable { let utilization: Double?; let resets_at: String? }
        struct Extra: Decodable {
            let is_enabled: Bool?
            let monthly_limit: Double?
            let used_credits: Double?
            let utilization: Double?
        }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let group: String?
            let percent: Double?
            let resets_at: String?
            let scope: Scope?
        }
        struct Payload: Decodable {
            let five_hour: Bucket?
            let seven_day: Bucket?
            let extra_usage: Extra?
            let limits: [Limit]?
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }
        // Caption + rolling length for a known window group, or nil to skip an
        // unrecognized one. A scoped window is prefixed with its model name so a
        // per-model weekly window reads e.g. "Fable 7-Day".
        func window(for limit: Limit) -> UsageWindow? {
            let base: String, length: TimeInterval
            switch limit.group {
            case "session": (base, length) = ("5-Hour", WindowLength.fiveHour)
            case "weekly":  (base, length) = ("7-Day", WindowLength.sevenDay)
            default:        return nil
            }
            let model = limit.scope?.model?.display_name
            let scoped = model?.isEmpty == false
            let caption = scoped ? "\(model!) \(base)" : base
            return UsageWindow(caption: caption, utilization: limit.percent ?? 0,
                               resetsAt: parseDate(limit.resets_at),
                               timeBasis: .rollingWindow(length: length),
                               isScoped: scoped)
        }
        // Legacy fallback: a fixed 5-hour + 7-day pair, always rendered (null fields
        // read as an idle 0% window).
        func legacyWindow(_ b: Bucket?, caption: String, length: TimeInterval) -> UsageWindow {
            UsageWindow(caption: caption, utilization: b?.utilization ?? 0,
                        resetsAt: parseDate(b?.resets_at),
                        timeBasis: .rollingWindow(length: length))
        }
        func parseExtra(_ e: Extra?) -> SpendInfo? {
            guard let e else { return nil }
            // `used_credits`/`monthly_limit` are already in cents (minor units). Claude's
            // payload carries NO reset timestamp for this monthly overage meter (verified
            // against a live response: neither `extra_usage` nor the newer `spend` object
            // has one), and Anthropic doesn't document the reset time/timezone — so we
            // leave `cycleResetsAt` nil and the ledger falls back to value-drop detection.
            return SpendInfo(usedCents: e.used_credits ?? 0, apiLimitCents: e.monthly_limit,
                             label: "Claude extra usage", cycleResetsAt: nil)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let windows: [UsageWindow]
        if let limits = payload.limits, !limits.isEmpty {
            windows = limits.compactMap(window)
        } else {
            windows = [
                legacyWindow(payload.five_hour, caption: "5-Hour", length: WindowLength.fiveHour),
                legacyWindow(payload.seven_day, caption: "7-Day", length: WindowLength.sevenDay),
            ]
        }
        return ProviderSnapshot(windows: windows, spend: parseExtra(payload.extra_usage))
    }
}
