import Foundation

/// Live usage for Devin. Reproduces the "usage meter" in Devin Desktop, which reads
/// the included daily/weekly quota from the Codeium/Windsurf backend, and adds the
/// on-demand (overage) dollars from the Devin webapp's billing API.
///
/// Two data sources, one shared token (the Windsurf session key from `DevinAuth`):
///
///   • **Quota rings** — a Connect RPC to
///     `server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus`,
///     with the token passed as request metadata. `userStatus.planStatus` carries
///     `dailyQuotaRemainingPercent` / `weeklyQuotaRemainingPercent` and their reset
///     unix timestamps — the exact numbers Devin Desktop shows. This is the source of
///     truth and, if it fails, the whole fetch fails.
///
///   • **Overage dollars** — the Devin webapp's `metrics/usage-by-user`, filtered to
///     this user's row over the current billing cycle (`billing/subscription`), giving
///     the actual on-demand dollars billed against the org's credit pool. This is
///     best-effort: a failure here still yields the quota rings, just without a spend
///     contribution.
final class DevinUsageFetcher: UsageProvider, @unchecked Sendable {
    let id: ProviderID = .devin
    let displayName = "Devin"
    let suggestedInterval: TimeInterval = 5 * 60

    private static let statusURL = URL(
        string: "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")!
    private static let webappHost = "app.devin.ai"
    private static let timeout: TimeInterval = 8

    /// The Codeium metadata block validates these four fields (the token alone is
    /// rejected with 400), so they are always sent. Their values are cosmetic.
    private static let ideName = "devin"
    private static let ideVersion = "1.0"
    private static let extensionName = "devin"
    private static let extensionVersion = "1.0.0"

    /// A Devin/webapp API returned a non-2xx status.
    struct APIError: Error, RawResponseCarrying {
        let endpoint: String
        let status: Int
        let body: String
        var rawResponse: String { "\(endpoint) → HTTP \(status)\n\(body)" }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let loadSession: @Sendable () throws -> DevinAuth.Session
    private let transport: Transport

    init(loadSession: (@Sendable () throws -> DevinAuth.Session)? = nil,
         transport: Transport? = nil) {
        self.loadSession = loadSession ?? { try DevinAuth.loadSession() }
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
    }

    func fetch() async throws -> FetchResult {
        let session = try loadSession()

        // Quota rings — the primary signal. A failure here fails the fetch.
        let (statusData, statusRaw) = try await getUserStatus(token: session.token)
        let status = try Self.decodeStatus(statusData)

        // Overage dollars — best-effort. Never let it sink the quota rings.
        var spend: SpendInfo?
        do {
            spend = try await fetchOverage(session: session, email: status.email)
        } catch {
            Log.log("usage[devin]: overage lookup failed (rings still shown): \(error)")
        }

        return FetchResult(snapshot: ProviderSnapshot(windows: status.windows, spend: spend), raw: statusRaw)
    }

    func classify(_ error: Error) -> String {
        switch error {
        case let e as ResponseParseError:
            return classify(e.underlying)
        case is DevinAuth.NotSignedInError:
            return "Not signed in to Devin (no Devin CLI or Devin Desktop login found)"
        case let e as APIError where e.endpoint.contains("GetUserStatus"):
            return "Devin usage API returned \(e.status)"
        case let e as APIError:
            return "Devin billing API returned \(e.status)"
        case let e as URLError:
            return "Network error: \(e.localizedDescription)"
        case is DecodingError:
            return "Couldn't parse the Devin usage response"
        default:
            return "Fetch failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Quota (Codeium GetUserStatus)

    private func getUserStatus(token: String) async throws -> (Data, String) {
        var req = URLRequest(url: Self.statusURL, timeoutInterval: Self.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let body: [String: Any] = ["metadata": [
            "api_key": token,
            "ide_name": Self.ideName,
            "ide_version": Self.ideVersion,
            "extension_name": Self.extensionName,
            "extension_version": Self.extensionVersion,
        ]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport(req)
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let http = response as? HTTPURLResponse else {
            throw APIError(endpoint: "GetUserStatus", status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(endpoint: "GetUserStatus", status: http.statusCode, body: raw)
        }
        return (data, raw)
    }

    struct DecodedStatus { let windows: [UsageWindow]; let email: String }

    /// Maps a `GetUserStatus` body into the daily/weekly quota windows plus the
    /// caller's email (used to find their row in the overage lookup). Exposed for
    /// tests; the network shape is exercised via the live fetch.
    static func decodeStatus(_ data: Data) throws -> DecodedStatus {
        struct PlanStatus: Decodable {
            // The quota percentages come as JSON numbers but the reset unix timestamps
            // come as numeric strings, so every field is decoded leniently.
            let dailyQuotaRemainingPercent: FlexibleNumber?
            let weeklyQuotaRemainingPercent: FlexibleNumber?
            let dailyQuotaResetAtUnix: FlexibleNumber?
            let weeklyQuotaResetAtUnix: FlexibleNumber?
        }
        struct UserStatus: Decodable { let email: String?; let planStatus: PlanStatus? }
        struct Payload: Decodable { let userStatus: UserStatus? }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ResponseParseError(rawResponse: String(data: data, encoding: .utf8) ?? "", underlying: error)
        }
        let plan = payload.userStatus?.planStatus

        // A "remaining %" becomes a utilization (used %). Each window appears only when
        // its percentage is present, so a plan without daily/weekly quota simply
        // contributes no ring rather than a misleading 0%.
        func window(remaining: FlexibleNumber?, resetUnix: FlexibleNumber?,
                    caption: String, length: TimeInterval) -> UsageWindow? {
            guard let remaining = remaining?.value else { return nil }
            let reset = resetUnix?.value.map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(caption: caption,
                               utilization: max(0, 100 - remaining),
                               resetsAt: reset,
                               timeBasis: .rollingWindow(length: length))
        }

        let windows = [
            window(remaining: plan?.dailyQuotaRemainingPercent, resetUnix: plan?.dailyQuotaResetAtUnix,
                   caption: "Daily", length: 24 * 60 * 60),
            window(remaining: plan?.weeklyQuotaRemainingPercent, resetUnix: plan?.weeklyQuotaResetAtUnix,
                   caption: "Weekly", length: WindowLength.sevenDay),
        ].compactMap { $0 }

        return DecodedStatus(windows: windows, email: payload.userStatus?.email ?? "")
    }

    /// A JSON value that may arrive as a number or a numeric string. Devin's status
    /// payload mixes the two (percentages as numbers, unix timestamps as strings), and
    /// the split isn't guaranteed stable, so every numeric quota field tolerates both.
    private struct FlexibleNumber: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { value = n }
            else if let s = try? c.decode(String.self) { value = Double(s) }
            else { value = nil }
        }
    }

    // MARK: - Overage (Devin webapp billing API)

    /// The on-demand dollars this user has been billed in the current billing cycle,
    /// as a spend contribution. `nil` when there is no per-user row (no on-demand use).
    private func fetchOverage(session: DevinAuth.Session, email: String) async throws -> SpendInfo? {
        let orgID = try await resolveOrgID(session: session)
        let cycle = try await fetchBillingCycle(token: session.token)
        let dollars = try await fetchMyCycleDollars(token: session.token, orgID: orgID,
                                                    email: email, cycle: cycle)
        // The billing-cycle end is Devin's own meter-reset instant — the ledger's
        // authoritative reset signal for reconstructing the local calendar month.
        return SpendInfo(usedCents: dollars * 100, apiLimitCents: nil,
                         label: "Devin on-demand", cycleResetsAt: cycle.end)
    }

    private struct BillingCycle { let start: Date; let end: Date? }

    private func fetchBillingCycle(token: String) async throws -> BillingCycle {
        struct Subscription: Decodable { let current_period_start: Double?; let current_period_end: Double? }
        let sub: Subscription = try await getJSON(token: token, path: "api/billing/subscription")
        // Fall back to a 30-day lookback if the subscription omits a cycle start, so the
        // dollar figure degrades to "recent" rather than failing outright.
        let start = sub.current_period_start.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let end = sub.current_period_end.map { Date(timeIntervalSince1970: $0) }
        return BillingCycle(start: start, end: end)
    }

    private func fetchMyCycleDollars(token: String, orgID: String, email: String,
                                     cycle: BillingCycle) async throws -> Double {
        struct User: Decodable { let user_email: String? }
        struct Metrics: Decodable { let total_dollars: Double? }
        struct Item: Decodable { let user: User?; let sessions_metrics: Metrics? }
        struct Page: Decodable { let items: [Item]?; let has_more: Bool? }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(identifier: "UTC")
        let start = iso.string(from: cycle.start)
        let end = iso.string(from: Date())
        let target = email.lowercased()

        // Page until this user's row is found; bound the paging so a large org can't
        // stall the refresh. The row is our own, so it is almost always on page one.
        for page in 1...20 {
            let query = [
                URLQueryItem(name: "start_date", value: start),
                URLQueryItem(name: "end_date", value: end),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: "100"),
                URLQueryItem(name: "sort_by", value: "sessions_created_count"),
                URLQueryItem(name: "sort_order", value: "desc"),
            ]
            let body: Page = try await getJSON(
                token: token,
                path: "api/organizations/\(orgID)/metrics/usage-by-user",
                query: query)
            let items = body.items ?? []
            if let mine = items.first(where: { $0.user?.user_email?.lowercased() == target }) {
                return mine.sessions_metrics?.total_dollars ?? 0
            }
            if body.has_more != true || items.isEmpty { break }
        }
        return 0
    }

    /// The org id from the CLI config, or resolved from the membership endpoint (which
    /// also validates the token). Cached-config path is the common case.
    private func resolveOrgID(session: DevinAuth.Session) async throws -> String {
        if !session.orgID.isEmpty { return session.orgID }
        struct Org: Decodable { let org_id: String? }
        struct Membership: Decodable { let org: Org? }
        let membership: Membership = try await getJSON(token: session.token, path: "api/users/current-membership")
        return membership.org?.org_id ?? ""
    }

    private func getJSON<T: Decodable>(token: String, path: String,
                                       query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.webappHost
        components.path = "/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw APIError(endpoint: path, status: -1, body: "could not build URL")
        }

        var req = URLRequest(url: url, timeoutInterval: Self.timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(endpoint: path, status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(endpoint: path, status: http.statusCode,
                           body: String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ResponseParseError(rawResponse: String(data: data, encoding: .utf8) ?? "", underlying: error)
        }
    }
}
