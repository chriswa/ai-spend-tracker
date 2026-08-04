import Foundation

/// Live usage for OpenAI Codex CLI (ChatGPT-authenticated). Mirrors what the
/// `codex` CLI's `/status` does:
///   • read the bearer token + account id from `~/.codex/auth.json` (never write it —
///     see `CodexCLIAuth` for why the CLI must own that file);
///   • GET https://chatgpt.com/backend-api/wham/usage with the bearer token and the
///     ChatGPT-Account-Id header.
///
/// That access token lives about an hour and Codex only refreshes it when Codex
/// itself runs, so a tray polling in the background routinely finds a stale one. On a
/// 401 we hand the refresh to the CLI (`CodexCLIAuth`) and retry once, which keeps the
/// tray self-healing without us ever touching the shared credential.
///
/// The payload carries `rate_limit.primary_window` / `secondary_window` (on paid
/// plans a 5-hour + weekly pair; on the free plan a single ~30-day window) plus
/// `spend_control.individual_limit` — the monthly workspace credit pool, reported
/// in *credits* (not dollars), which we value at an estimated per-credit rate.
final class CodexUsageFetcher: UsageProvider, @unchecked Sendable {
    let id: ProviderID = .codex
    let displayName = "Codex"
    let suggestedInterval: TimeInterval = 5 * 60

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let userAgent = "codex-usage-tray"
    private static let timeout: TimeInterval = 5

    /// Codex reports the monthly workspace pool in credits, not dollars. The
    /// workspace's own rate is ≈ US$0.04/credit (a CA$1,120 / 20,000-credit
    /// allowance), i.e. 4 cents per credit. This is an estimate: treat the derived
    /// dollar figures as approximate until Codex exposes billed amounts directly.
    private static let centsPerCredit = 4.0

    /// `~/.codex/auth.json` is missing or has no access token — Codex isn't logged in.
    struct NoAuthError: Error {}
    /// The usage endpoint returned a non-2xx status.
    struct UsageAPIError: Error, RawResponseCarrying {
        let status: Int; let body: String
        var rawResponse: String { "HTTP \(status)\n\(body)" }
    }
    /// The token was expired and handing the refresh to the `codex` CLI didn't work.
    /// Carries the 401 body too, so "copy last response" still shows what we saw.
    struct TokenRefreshError: Error, RawResponseCarrying {
        let detail: String
        let expiredResponse: String
        var rawResponse: String { "token refresh failed: \(detail)\n\n\(expiredResponse)" }
    }

    /// Refreshing rotates the refresh token, so overlapping refreshes can invalidate
    /// each other. `refreshGate` serializes ours and spaces them out — a 401 that
    /// survives a *fresh* refresh means the account needs a re-login, and hammering
    /// the token endpoint (e.g. by mashing "Refresh Now") won't fix it.
    private static let refreshCooldown: TimeInterval = 60

    /// Issues one HTTP request. Injected so tests can drive the retry path.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let authPath: URL
    /// Performs the refresh. Injected so tests can drive the retry path without
    /// spawning a process.
    private let refreshAuth: @Sendable () async throws -> Void
    private let transport: Transport
    private let refreshGate: RefreshGate

    init(authPath: URL? = nil,
         refreshCooldown: TimeInterval = CodexUsageFetcher.refreshCooldown,
         refreshAuth: (@Sendable () async throws -> Void)? = nil,
         transport: Transport? = nil) {
        self.authPath = authPath
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        self.refreshAuth = refreshAuth ?? { try await CodexCLIAuth.refreshToken() }
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
        self.refreshGate = RefreshGate(cooldown: refreshCooldown)
    }

    func fetch() async throws -> FetchResult {
        do {
            return try await fetchUsage()
        } catch let expired as UsageAPIError where expired.status == 401 {
            try await refresh(after: expired)
            // Re-reads auth.json, which the CLI has just rewritten. Exactly one retry:
            // a second 401 is an authorization problem, not a stale token.
            return try await fetchUsage()
        }
    }

    /// Ask the CLI to refresh. Throws `TokenRefreshError` if it can't, so the 401 is
    /// reported as "couldn't auto-refresh" rather than a bare expiry.
    private func refresh(after expired: UsageAPIError) async throws {
        guard await refreshGate.claim() else {
            throw TokenRefreshError(detail: "refreshed moments ago and still unauthorized",
                                    expiredResponse: expired.rawResponse)
        }
        do {
            try await refreshAuth()
            Log.log("usage[codex]: token expired — refreshed via the codex CLI, retrying")
        } catch {
            throw TokenRefreshError(detail: Self.describe(refreshFailure: error),
                                    expiredResponse: expired.rawResponse)
        }
    }

    private static func describe(refreshFailure error: Error) -> String {
        switch error {
        case is CodexCLIAuth.CLINotFound: return "no codex CLI found to refresh it"
        case let e as CodexCLIAuth.RefreshFailed: return e.detail
        default: return error.localizedDescription
        }
    }

    /// One request to the usage endpoint with whatever token is on disk right now.
    private func fetchUsage() async throws -> FetchResult {
        let (token, accountId) = try readAuth()

        var req = URLRequest(url: Self.usageURL, timeoutInterval: Self.timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")

        let (data, response) = try await transport(req)
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageAPIError(status: http.statusCode, body: raw)
        }
        do {
            return FetchResult(snapshot: try Self.decode(data), raw: raw)
        } catch {
            throw ResponseParseError(rawResponse: raw, underlying: error)
        }
    }

    func classify(_ error: Error) -> String {
        switch error {
        case let e as ResponseParseError:
            return classify(e.underlying)
        case is NoAuthError:
            return "Not logged in to Codex (~/.codex/auth.json missing)"
        case let e as TokenRefreshError:
            return "Codex token expired — \(e.detail)"
        case let e as UsageAPIError where e.status == 401:
            // Only reachable after a successful refresh, so the token isn't the problem.
            return "Codex rejected our sign-in — run `codex login` again"
        case let e as UsageAPIError:
            return "Codex usage API returned \(e.status)"
        case let e as URLError:
            return "Network error: \(e.localizedDescription)"
        case is DecodingError:
            return "Couldn't parse the Codex usage response"
        default:
            return "Fetch failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Auth

    /// Serializes refresh attempts and enforces a minimum gap between them, so
    /// concurrent or rapid-fire fetches can't stack up token exchanges.
    actor RefreshGate {
        private let cooldown: TimeInterval
        private var lastAttempt: Date?

        init(cooldown: TimeInterval) { self.cooldown = cooldown }

        /// `true` if the caller may refresh now; `false` if one just happened.
        func claim(now: Date = Date()) -> Bool {
            if let last = lastAttempt, now.timeIntervalSince(last) < cooldown { return false }
            lastAttempt = now
            return true
        }
    }

    private func readAuth() throws -> (token: String, accountId: String) {
        guard let raw = try? Data(contentsOf: authPath),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw NoAuthError()
        }
        let accountId = (tokens["account_id"] as? String) ?? ""
        return (token, accountId)
    }

    // MARK: - Decode

    /// Map the `wham/usage` payload into a `ProviderSnapshot`. Both windows are
    /// optional (free plans have only `primary_window`); missing fields read as an
    /// idle window rather than failing the fetch.
    static func decode(_ data: Data) throws -> ProviderSnapshot {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Double?
            let reset_at: Double?
        }
        struct RateLimit: Decodable { let primary_window: Window?; let secondary_window: Window? }
        // Codex encodes the credit-pool figures as either JSON numbers or numeric
        // strings depending on plan/endpoint version; accept both.
        struct FlexibleNumber: Decodable {
            let value: Double
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let n = try? c.decode(Double.self) { value = n }
                else if let s = try? c.decode(String.self), let n = Double(s) { value = n }
                else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected number or numeric string") }
            }
        }
        struct SpendLimit: Decodable { let limit: FlexibleNumber?; let used: FlexibleNumber?; let remaining: FlexibleNumber?; let reset_at: Double? }
        struct SpendControl: Decodable { let individual_limit: SpendLimit? }
        struct Payload: Decodable {
            let plan_type: String?
            let rate_limit: RateLimit?
            let spend_control: SpendControl?
        }

        func window(_ w: Window?) -> UsageWindow? {
            guard let w, let seconds = w.limit_window_seconds, seconds > 0 else { return nil }
            let reset = w.reset_at.map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(caption: WindowCaption.forLength(seconds),
                               utilization: w.used_percent ?? 0, resetsAt: reset,
                               timeBasis: .rollingWindow(length: seconds))
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let windows = [payload.rate_limit?.primary_window, payload.rate_limit?.secondary_window]
            .compactMap(window)

        // Overage: `individual_limit` reports the monthly workspace pool in credits
        // (number or numeric string). Value it at the estimated per-credit rate, and
        // contribute only when a limit is actually configured (nil on free plans → no
        // spend).
        var spend: SpendInfo?
        if let limit = payload.spend_control?.individual_limit,
           let usedCredits = limit.used?.value {
            // `reset_at` is the credit pool's own cycle boundary — the ledger's
            // authoritative reset signal for Codex spend.
            spend = SpendInfo(usedCents: usedCredits * centsPerCredit,
                              apiLimitCents: (limit.limit?.value).map { $0 * centsPerCredit },
                              label: "Codex overage",
                              cycleResetsAt: limit.reset_at.map { Date(timeIntervalSince1970: $0) })
        }
        return ProviderSnapshot(windows: windows, spend: spend)
    }
}
