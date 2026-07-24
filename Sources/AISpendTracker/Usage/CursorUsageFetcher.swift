import Foundation

/// Live usage for Cursor. Mirrors what the cursor.com dashboard does:
///   • read the session JWT from the login Keychain item "cursor-access-token"
///     (account "cursor-user") via `security`;
///   • POST https://cursor.com/api/usage-summary authenticated by the
///     `WorkosCursorSessionToken=<userId>::<jwt>` cookie (+ an Origin header the
///     endpoint's CSRF guard requires). `userId` is the JWT `sub` after the "|".
///
/// The payload reports included-usage percentage (`individualUsage.plan`),
/// on-demand/overage spend (`individualUsage.onDemand`, in cents), and the monthly
/// billing cycle (`billingCycleStart`/`End`) — so Cursor renders as a single monthly
/// window plus a spend contribution.
final class CursorUsageFetcher: UsageProvider, @unchecked Sendable {
    let id: ProviderID = .cursor
    let displayName = "Cursor"
    let suggestedInterval: TimeInterval = 5 * 60

    private static let keychainService = "cursor-access-token"
    private static let keychainAccount = "cursor-user"
    private static let usageURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let timeout: TimeInterval = 5

    /// No Cursor session token in the Keychain — not signed in.
    struct NoCredentialsError: Error {}
    /// Transient Keychain failure. `detail` is the tool's stderr.
    struct KeychainError: Error { let detail: String }
    /// The token wasn't a decodable JWT (can't derive the userId the cookie needs).
    struct MalformedTokenError: Error {}
    /// The endpoint returned the app's HTML shell rather than JSON — usually an
    /// account type/route this scraping approach doesn't support yet. Carries the
    /// body so the user can copy and share it.
    struct UnsupportedResponseError: Error, RawResponseCarrying {
        let body: String
        var rawResponse: String { body }
    }
    /// The usage endpoint returned a non-2xx status.
    struct UsageAPIError: Error, RawResponseCarrying {
        let status: Int; let body: String
        var rawResponse: String { "HTTP \(status)\n\(body)" }
    }

    func fetch() async throws -> FetchResult {
        let jwt = try readToken()
        let userId = try Self.userId(fromJWT: jwt)

        var req = URLRequest(url: Self.usageURL, timeoutInterval: Self.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        req.setValue("WorkosCursorSessionToken=\(userId)::\(jwt)", forHTTPHeaderField: "Cookie")
        req.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageAPIError(status: http.statusCode, body: raw)
        }
        // A 200 that's actually the Next.js app shell means the route/account isn't
        // supported for this scraping path — surface it distinctly.
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).first == "<" {
            throw UnsupportedResponseError(body: raw)
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
        case is NoCredentialsError:
            return "Not signed in to Cursor (no Keychain token)"
        case is MalformedTokenError:
            return "Cursor token wasn't a readable JWT"
        case is UnsupportedResponseError:
            return "Cursor account type not supported yet — copy this error and share it"
        case let e as KeychainError:
            return "Keychain read failed: \(e.detail)"
        case let e as UsageAPIError:
            return "Cursor usage API returned \(e.status)"
        case let e as URLError:
            return "Network error: \(e.localizedDescription)"
        case is DecodingError:
            return "Couldn't parse the Cursor usage response"
        default:
            return "Fetch failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Auth

    private func readToken() throws -> String {
        do {
            return try Keychain.readGenericPassword(service: Self.keychainService, account: Self.keychainAccount)
        } catch is Keychain.ItemNotFound {
            throw NoCredentialsError()
        } catch let e as Keychain.AccessError {
            throw KeychainError(detail: e.detail)
        }
    }

    /// The user id the cookie needs: the JWT `sub` claim after the "|"
    /// (e.g. "google-oauth2|user_01J…" → "user_01J…").
    static func userId(fromJWT jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sub = json["sub"] as? String else {
            throw MalformedTokenError()
        }
        return String(sub.split(separator: "|").last ?? Substring(sub))
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        return Data(base64Encoded: b64)
    }

    // MARK: - Decode

    static func decode(_ data: Data) throws -> ProviderSnapshot {
        struct Plan: Decodable { let totalPercentUsed: Double? }
        struct OnDemand: Decodable { let used: Double?; let limit: Double? }
        struct Individual: Decodable { let plan: Plan?; let onDemand: OnDemand? }
        struct Payload: Decodable {
            let billingCycleStart: String?
            let billingCycleEnd: String?
            let isUnlimited: Bool?
            let individualUsage: Individual?
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let start = parseDate(payload.billingCycleStart)
        let end = parseDate(payload.billingCycleEnd)
        // `totalPercentUsed` is already a 0…100 percentage — it matches the dashboard's
        // "You've used N% of your included total usage" string (e.g. 17.71 → "18%").
        let utilization = payload.individualUsage?.plan?.totalPercentUsed ?? 0

        let basis: TimeBasis = (start != nil && end != nil) ? .interval(start: start!, end: end!) : .none
        let window = UsageWindow(caption: "Monthly", utilization: utilization, resetsAt: end, timeBasis: basis)

        // On-demand `used` is in cents. `billingCycleEnd` is when this on-demand meter
        // rolls over — the ledger's authoritative reset signal for Cursor spend.
        var spend: SpendInfo?
        if let onDemand = payload.individualUsage?.onDemand {
            spend = SpendInfo(usedCents: onDemand.used ?? 0, apiLimitCents: onDemand.limit,
                              label: "Cursor on-demand", cycleResetsAt: end)
        }
        return ProviderSnapshot(windows: [window], spend: spend)
    }
}
