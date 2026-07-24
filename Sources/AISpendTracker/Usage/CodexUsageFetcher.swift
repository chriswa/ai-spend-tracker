import Foundation

/// Live usage for OpenAI Codex CLI (ChatGPT-authenticated). Mirrors what the
/// `codex` CLI's `/status` does:
///   • read the bearer token + account id from `~/.codex/auth.json` (the CLI
///     refreshes this file itself; we only read it — never write, to avoid racing
///     the running CLI);
///   • GET https://chatgpt.com/backend-api/wham/usage with the bearer token and the
///     ChatGPT-Account-Id header.
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

    private let authPath: URL

    init(authPath: URL? = nil) {
        self.authPath = authPath
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    func fetch() async throws -> FetchResult {
        let (token, accountId) = try readAuth()

        var req = URLRequest(url: Self.usageURL, timeoutInterval: Self.timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")

        let (data, response) = try await URLSession.shared.data(for: req)
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
        case let e as UsageAPIError where e.status == 401:
            return "Codex token expired — open Codex to refresh it"
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
