import Foundation

/// One account's last reading of a provider. The active account (the one the latest
/// fetch was signed into) shows its reading as fetched; every other account's reading is
/// carried forward on the assumption that nothing was used since — each window holds
/// until its reset passes, then reads as idle.
struct AccountView {
    /// Nil for a provider without accounts (it has exactly one `AccountView`).
    var account: AccountRef?
    var snapshot: ProviderSnapshot
    /// When this reading was fetched; nil only for preview data.
    var lastUpdated: Date?
    var isActive: Bool
    /// This account's spend reconstructed onto the local calendar month (see
    /// `SpendLedger`). Nil until it has reported spend at least once.
    var reconstructedSpend: SpendLedger.Entry?

    /// The windows as they stand at `now`.
    func windows(now: Date) -> [UsageWindow] {
        isActive ? snapshot.windows : snapshot.windows.map { $0.assumingNoUseSince(now: now) }
    }

    /// The instant the time wedge is measured at. The active account's is its fetch, so
    /// time never races ahead of the frozen usage reading; an inactive account's is now,
    /// since its windows have been carried forward to now.
    func timeAnchor(now: Date) -> Date { isActive ? lastUpdated ?? now : now }

    /// The spend this account contributes to the current local calendar month: the
    /// ledger's reconstruction, or the raw reading when none exists yet (mock/preview
    /// data). An inactive account isn't re-ingested, so a ledger month that has since
    /// ended counts for nothing.
    func monthSpendCents(now: Date) -> Double? {
        guard let spend = snapshot.spend else { return nil }
        guard let e = reconstructedSpend else { return spend.usedCents }
        if !isActive && e.calendarMonthKey != SpendLedger.monthKey(now) { return 0 }
        return e.monthSpendCents
    }
}

/// One enabled provider's current state for display: every account's last good reading
/// (empty until the first success), its current error (nil when the last fetch
/// succeeded), and its rolling history for sparklines. A provider with a non-nil `error`
/// renders as a warning glyph in its slot; its readings may still feed the dropdown text.
struct ProviderView {
    let id: ProviderID
    let displayName: String
    /// Every account's last reading, in first-detected order. A provider without
    /// accounts has at most one.
    var accounts: [AccountView]
    var error: String?
    var history: [UsageHistory.Sample]
    /// The provider's most recent raw response body, for the "copy last response"
    /// affordance. Nil until we've recorded one.
    var lastRawResponse: String?

    /// Pass `accounts`, or for a provider without accounts just its `snapshot` (fetched
    /// at `lastUpdated`, reconstructed as `reconstructedSpend`).
    init(id: ProviderID, displayName: String, snapshot: ProviderSnapshot? = nil,
         lastUpdated: Date? = nil, error: String? = nil, history: [UsageHistory.Sample] = [],
         lastRawResponse: String? = nil, reconstructedSpend: SpendLedger.Entry? = nil,
         accounts: [AccountView]? = nil) {
        self.id = id
        self.displayName = displayName
        self.accounts = accounts ?? snapshot.map {
            [AccountView(account: $0.account, snapshot: $0, lastUpdated: lastUpdated,
                         isActive: true, reconstructedSpend: reconstructedSpend)]
        } ?? []
        self.error = error
        self.history = history
        self.lastRawResponse = lastRawResponse
    }

    /// The active account's view — the one the latest successful fetch was signed into.
    var activeAccount: AccountView? { accounts.first { $0.isActive } }

    /// The active account's last good snapshot (nil until the first success).
    var snapshot: ProviderSnapshot? {
        get { activeAccount?.snapshot }
        set {
            accounts.removeAll { $0.isActive && newValue == nil }
            guard let newValue else { return }
            if let i = accounts.firstIndex(where: \.isActive) {
                accounts[i].snapshot = newValue
            } else {
                accounts.append(AccountView(account: newValue.account, snapshot: newValue,
                                            lastUpdated: nil, isActive: true))
            }
        }
    }

    /// When the active account's snapshot was fetched.
    var lastUpdated: Date? { activeAccount?.lastUpdated }

    /// Whether the user has been seen signed into more than one account — the only case
    /// where the display needs to say which one is active.
    var hasMultipleAccounts: Bool { accounts.count > 1 }
}

/// The whole tray's state: the ordered enabled providers plus the single spend total
/// the combined spend pie fills against. Shared source of truth for the tray image,
/// the dropdown header rings, and the menu sections.
struct TrayViewModel {
    var providers: [ProviderView]
    var customLimitCents: Double
    /// How the combined spend renders in the tray (the dropdown always keeps the ring).
    var spendDisplayMode: SpendDisplayMode = .circle
    /// Whether the tray draws rings or bars (the dropdown always keeps rings).
    var trayStyle: TrayStyle = .rings
    /// Per-model window captions the user has hidden; they draw no circle anywhere.
    var hiddenScopedWindows: Set<String> = []

    /// Every per-model window caption any account reports, in first-seen order — the
    /// windows the user can toggle.
    var scopedWindowCaptions: [String] {
        var seen: [String] = []
        for a in providers.flatMap(\.accounts) {
            for w in a.snapshot.windows where w.isScoped && !seen.contains(w.caption) { seen.append(w.caption) }
        }
        return seen
    }

    /// Sum of every enabled provider's spend for the current local calendar month —
    /// the ledger's reconstructed figure, falling back to the provider's raw month-to-date
    /// only when no reconstruction exists yet (e.g. mock/preview data).
    var combinedSpendCents: Double {
        let now = Date()
        return providers.flatMap(\.accounts).compactMap { $0.monthSpendCents(now: now) }.reduce(0, +)
    }

    /// Whether any enabled provider reports spend at all (gates the spend pie).
    var hasAnySpend: Bool {
        providers.contains { p in p.accounts.contains { $0.snapshot.spend != nil } }
    }

    /// Most recent successful fetch across providers (for the "Updated … ago" line).
    var latestUpdate: Date? {
        providers.compactMap { $0.lastUpdated }.max()
    }

    /// Combined cumulative spend (cents) over time, for the spend sparkline / peak.
    ///
    /// Providers sample at different (often sub-second-apart) instants, so naively
    /// summing by timestamp yields a jagged series whose per-minute rate explodes on
    /// the tiny gaps. Instead we sample at the union of all timestamps and, at each
    /// instant, sum every provider's *linearly interpolated* cumulative spend (a
    /// blend of its two surrounding samples). Each provider's contribution is then
    /// piecewise-linear, so `delta / gap` recovers the true combined slope regardless
    /// of how close two points sit — reasonable rather than pedantically exact. Each
    /// provider account is its own series, so switching accounts doesn't read as a
    /// plunge from one account's spend to the other's.
    var spendSeries: [(Date, Double)] {
        let series = providers
            .flatMap { p in Dictionary(grouping: p.history, by: \.account).values }
            .map { samples in samples.compactMap { s in s.spendCents.map { (s.date, $0) } } }
            .filter { !$0.isEmpty }
        guard !series.isEmpty else { return [] }
        let times = Set(series.flatMap { $0.map(\.0) }).sorted()
        return times.map { t in (t, series.reduce(0) { $0 + Self.interpolate($1, at: t) }) }
    }

    /// A provider's cumulative spend at `t`, linearly interpolated between its
    /// surrounding samples and held flat outside its sampled range.
    private static func interpolate(_ points: [(Date, Double)], at t: Date) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 1..<points.count where points[i].0 >= t {
            let (t0, v0) = points[i - 1], (t1, v1) = points[i]
            let span = t1.timeIntervalSince(t0)
            return span > 0 ? v0 + (v1 - v0) * (t.timeIntervalSince(t0) / span) : v1
        }
        return last.1
    }
}

extension ProviderView {
    /// One account's cumulative utilization series for one window caption (oldest
    /// first) — the source for that window's sparkline / recent-peak.
    func series(forWindow caption: String, account: AccountRef?) -> [(Date, Double)] {
        history.filter { $0.account == account?.id }
            .compactMap { s in s.windows[caption].map { (s.date, $0) } }
    }
}
