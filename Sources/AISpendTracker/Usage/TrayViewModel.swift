import Foundation

/// One enabled provider's current state for display: its last good snapshot (nil
/// until the first success), when that arrived, its current error (nil when the last
/// fetch succeeded), and its rolling history for sparklines. A provider with a
/// non-nil `error` renders as a warning glyph in its slot; `snapshot` may still hold
/// the last good data for the dropdown text.
struct ProviderView {
    let id: ProviderID
    let displayName: String
    var snapshot: ProviderSnapshot?
    var lastUpdated: Date?
    var error: String?
    var history: [UsageHistory.Sample]
    /// The provider's most recent raw response body, for the "copy last response"
    /// affordance. Nil until we've recorded one.
    var lastRawResponse: String?
    /// The provider's spend reconstructed onto the user's local calendar month (see
    /// `SpendLedger`). This — not `snapshot.spend.usedCents` — is what we display and
    /// sum. Nil until the provider has reported spend at least once.
    var reconstructedSpend: SpendLedger.Entry?

    init(id: ProviderID, displayName: String, snapshot: ProviderSnapshot? = nil,
         lastUpdated: Date? = nil, error: String? = nil, history: [UsageHistory.Sample] = [],
         lastRawResponse: String? = nil, reconstructedSpend: SpendLedger.Entry? = nil) {
        self.id = id
        self.displayName = displayName
        self.snapshot = snapshot
        self.lastUpdated = lastUpdated
        self.error = error
        self.history = history
        self.lastRawResponse = lastRawResponse
        self.reconstructedSpend = reconstructedSpend
    }
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

    /// Sum of every enabled provider's spend for the current local calendar month —
    /// the ledger's reconstructed figure, falling back to the provider's raw month-to-date
    /// only when no reconstruction exists yet (e.g. mock/preview data).
    var combinedSpendCents: Double {
        providers.compactMap { $0.reconstructedSpend?.monthSpendCents ?? $0.snapshot?.spend?.usedCents }.reduce(0, +)
    }

    /// Whether any enabled provider reports spend at all (gates the spend pie).
    var hasAnySpend: Bool {
        providers.contains { $0.snapshot?.spend != nil }
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
    /// of how close two points sit — reasonable rather than pedantically exact.
    var spendSeries: [(Date, Double)] {
        let series = providers
            .map { p in p.history.compactMap { s in s.spendCents.map { (s.date, $0) } } }
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
    /// This provider's cumulative utilization series for one window caption (oldest
    /// first) — the source for that window's sparkline / recent-peak.
    func series(forWindow caption: String) -> [(Date, Double)] {
        history.compactMap { s in s.windows[caption].map { (s.date, $0) } }
    }
}
