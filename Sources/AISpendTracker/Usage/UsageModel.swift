import Foundation

/// The AI coding tools we can track. `rawValue` is used as the persistence key
/// (cache/history filenames, enabled-set storage) so it must stay stable.
/// `CaseIterable` order is the canonical left-to-right pie/section order.
enum ProviderID: String, CaseIterable, Codable {
    case claude, codex, cursor, devin, jev

    /// Whether the provider has rate-limit windows at all. A spend-only provider (Jev:
    /// pay-per-token, no subscription) draws no circle and only feeds the spend total.
    var hasUsageWindows: Bool { self != .jev }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex:  "Codex"
        case .cursor: "Cursor"
        case .devin:  "Devin"
        case .jev:    "Jev"
        }
    }
}

/// How a window's elapsed-time wedge (the gray/dark pie layer) is computed.
/// Different providers express their windows differently:
///   • `rollingWindow` — a fixed-length window that rolls over at `resetsAt`
///     (Claude 5h/7d, Codex primary/secondary). Elapsed = length − (resetsAt − now).
///   • `interval` — an explicit start…end span (Cursor's monthly billing cycle).
///   • `none` — no time information; the wedge reads as empty.
enum TimeBasis: Codable, Equatable {
    case rollingWindow(length: TimeInterval)
    case interval(start: Date, end: Date)
    case none
}

/// One rate-limit window — renders as one pie. `utilization` is a 0…100 percentage
/// (it can momentarily read slightly above 100 near a cap; text shows the raw value,
/// the ring clamps). `resetsAt` is when the window rolls over (also drives the
/// countdown text); nil for an idle window that hasn't started.
struct UsageWindow: Codable, Equatable {
    var caption: String
    var utilization: Double
    var resetsAt: Date?
    var timeBasis: TimeBasis
    /// Whether an end-of-window projection is meaningful (rolling/interval windows
    /// where "on pace" makes sense). Providers without a stable pace set this false.
    var supportsProjection: Bool
    /// A per-model scoped window (e.g. Claude's "Fable 7-Day") rather than one of the
    /// account-wide primary windows. Rendered in a distinct color so it doesn't read
    /// as another primary usage window.
    var isScoped: Bool

    init(caption: String, utilization: Double, resetsAt: Date?,
         timeBasis: TimeBasis, supportsProjection: Bool = true, isScoped: Bool = false) {
        self.caption = caption
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.timeBasis = timeBasis
        self.supportsProjection = supportsProjection
        self.isScoped = isScoped
    }
}

/// A provider's spend as the provider *itself* reports it — a raw month-to-date figure
/// measured against the provider's OWN billing cycle, in cents. This is an untranslated
/// reading, not yet aligned to the user's calendar month; `SpendLedger` reconstructs
/// the calendar-month total from a stream of these. `apiLimitCents` is the
/// provider-reported cap (informational only). `label` names the source in the menu.
///
/// `cycleResetsAt` is the provider's own next cycle-reset instant, when the API tells
/// us (Codex `individual_limit.reset_at`, Cursor `billingCycleEnd`). It is the ledger's
/// authoritative reset signal: when it changes, the provider's counter has rolled over.
/// It is **nil when the provider exposes no reset timestamp** (Claude) — the ledger then
/// falls back to detecting a reset from a drop in `usedCents`, which is less reliable
/// (see `SpendLedger`).
///
/// `isLocalCalendarMonth` marks a reading whose cycle *is* the user's local calendar
/// month, measured on this machine's clock (Jev, computed locally). The ledger takes such
/// a reading verbatim instead of reconstructing it. Optional so older caches decode.
struct SpendInfo: Codable, Equatable {
    var usedCents: Double
    var apiLimitCents: Double?
    var label: String
    var cycleResetsAt: Date?
    var isLocalCalendarMonth: Bool?

    init(usedCents: Double, apiLimitCents: Double?, label: String, cycleResetsAt: Date? = nil,
         isLocalCalendarMonth: Bool = false) {
        self.usedCents = usedCents
        self.apiLimitCents = apiLimitCents
        self.label = label
        self.cycleResetsAt = cycleResetsAt
        self.isLocalCalendarMonth = isLocalCalendarMonth ? true : nil
    }
}

extension UsageWindow {
    /// This window carried forward to `now` on the assumption that nothing was used since
    /// it was read: unchanged until its reset passes, then an idle 0% window (a rolling
    /// window doesn't restart until it's used again, so its next reset is unknown).
    func assumingNoUseSince(now: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        var idle = self
        idle.utilization = 0
        idle.resetsAt = nil
        if case .interval = timeBasis { idle.timeBasis = .none }
        return idle
    }
}

/// The login a reading belongs to, for a provider the user can be signed into under more
/// than one account (Claude: a personal plan and a Team seat, switched with `/login`).
/// `id` is the stable key for persistence and ordering; `label` is the short name shown
/// under the provider's name.
struct AccountRef: Codable, Equatable, Hashable {
    var id: String
    var label: String
}

/// What every provider returns from a successful fetch: an ordered list of windows
/// (0…N pies), an optional spend contribution, and an optional `warning` — a problem
/// worth showing even though the data is good (e.g. Jev's command running slowly).
/// Unlike a fetch error, a warning is shown on the first occurrence.
///
/// `account` names the signed-in account the reading came from, for providers that
/// report one (Claude). Nil for providers with no notion of multiple accounts — they
/// keep a single reading.
struct ProviderSnapshot: Codable, Equatable {
    var windows: [UsageWindow]
    var spend: SpendInfo?
    var warning: String?
    var account: AccountRef?

    init(windows: [UsageWindow] = [], spend: SpendInfo? = nil, warning: String? = nil,
         account: AccountRef? = nil) {
        self.windows = windows
        self.spend = spend
        self.warning = warning
        self.account = account
    }
}

/// Fixed window lengths shared by the fetchers.
enum WindowLength {
    static let fiveHour: TimeInterval = 5 * 60 * 60
    static let sevenDay: TimeInterval = 7 * 24 * 60 * 60
}

/// Derives a short, role-based caption from a rolling window's length, so a provider
/// that changes its windows (e.g. Codex going from a single monthly free-plan window
/// to a paid 5-hour + weekly pair) is labeled correctly with no code change.
enum WindowCaption {
    static func forLength(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<(6 * 3600):      return "5-Hour"
        case ..<(2 * 86400):     return "Daily"
        case ..<(8 * 86400):     return "Weekly"
        default:                 return "Monthly"
        }
    }
}
