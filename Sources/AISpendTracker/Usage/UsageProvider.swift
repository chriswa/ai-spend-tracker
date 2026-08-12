import Foundation

/// A source of usage data for one AI coding tool. The app talks only to this
/// protocol so providers are interchangeable and each owns its own auth, endpoint,
/// polling cadence, and error taxonomy. Kept AppKit-free — per-provider colors live
/// in the render layer, keyed by `id`.
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    /// Recommended seconds between fetches; the poller never fetches faster.
    var suggestedInterval: TimeInterval { get }
    func fetch() async throws -> FetchResult
    /// Turn a fetch error into a short, user-facing message. Every failure is
    /// transient — the poller shows this message and retries next cooldown.
    func classify(_ error: Error) -> String
}

/// A completed fetch: the parsed snapshot plus the exact response body it was parsed
/// from. The raw body is retained so the user can copy it for debugging / error
/// reports (each provider makes a single request, so this is unambiguous).
struct FetchResult {
    let snapshot: ProviderSnapshot
    let raw: String
}

/// An error that carries the raw provider response (or diagnostic text) it arose
/// from, so the poller can persist it as the provider's "last response" for copying.
/// Errors with no body (e.g. a missing credential) simply don't conform, and the
/// poller falls back to the human-readable message.
protocol RawResponseCarrying {
    var rawResponse: String { get }
}

/// A response we received but couldn't turn into a snapshot. Preserves both the raw
/// body (for copying) and the underlying decode error, so `classify` still reports it
/// as a parse failure. Fetchers wrap decode errors in this to keep the body.
struct ResponseParseError: Error, RawResponseCarrying {
    let rawResponse: String
    let underlying: Error
}

/// Fixed demo data for UI review — no network, no Keychain. Reset times are anchored
/// to real wall-clock times so the pies match the intended snapshot and the *time*
/// arcs keep advancing. Each mock provider mimics the real shape of its counterpart.
struct MockProvider: UsageProvider {
    let id: ProviderID
    let displayName: String
    let suggestedInterval: TimeInterval = 60
    private let snapshot: ProviderSnapshot

    init(id: ProviderID, now: Date = Date(), calendar: Calendar = .current) {
        self.id = id
        switch id {
        case .claude:
            displayName = "Claude"
            let fiveReset = calendar.date(bySettingHour: 13, minute: 30, second: 0, of: now) ?? now
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            let sevenReset = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow) ?? now
            snapshot = ProviderSnapshot(
                windows: [
                    UsageWindow(caption: "5-Hour", utilization: 45, resetsAt: fiveReset,
                                timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
                    UsageWindow(caption: "7-Day", utilization: 54, resetsAt: sevenReset,
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
                    UsageWindow(caption: "Fable 7-Day", utilization: 12, resetsAt: sevenReset,
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay), isScoped: true),
                ],
                spend: SpendInfo(usedCents: 12345, apiLimitCents: 50000, label: "Claude extra usage"))
        case .codex:
            displayName = "Codex"
            let reset = calendar.date(byAdding: .hour, value: 3, to: now) ?? now
            snapshot = ProviderSnapshot(
                windows: [
                    UsageWindow(caption: "5-Hour", utilization: 30, resetsAt: reset,
                                timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
                    UsageWindow(caption: "Weekly", utilization: 62,
                                resetsAt: calendar.date(byAdding: .day, value: 4, to: now),
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
                ],
                spend: SpendInfo(usedCents: 800, apiLimitCents: nil, label: "Codex overage"))
        case .cursor:
            displayName = "Cursor"
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
            snapshot = ProviderSnapshot(
                windows: [
                    UsageWindow(caption: "Monthly", utilization: 18, resetsAt: end,
                                timeBasis: .interval(start: start, end: end)),
                ],
                spend: SpendInfo(usedCents: 4200, apiLimitCents: 150000, label: "Cursor on-demand"))
        case .devin:
            displayName = "Devin"
            let dailyReset = calendar.date(byAdding: .hour, value: 11, to: now) ?? now
            let weeklyReset = calendar.date(byAdding: .day, value: 4, to: now) ?? now
            snapshot = ProviderSnapshot(
                windows: [
                    UsageWindow(caption: "Daily", utilization: 6, resetsAt: dailyReset,
                                timeBasis: .rollingWindow(length: 24 * 60 * 60)),
                    UsageWindow(caption: "Weekly", utilization: 3, resetsAt: weeklyReset,
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
                ],
                spend: SpendInfo(usedCents: 1761, apiLimitCents: nil, label: "Devin on-demand"))
        }
    }

    func fetch() async throws -> FetchResult {
        FetchResult(snapshot: snapshot, raw: "{\"mock\": \"\(id.rawValue)\"}")
    }
    func classify(_ error: Error) -> String {
        error.localizedDescription
    }
}
