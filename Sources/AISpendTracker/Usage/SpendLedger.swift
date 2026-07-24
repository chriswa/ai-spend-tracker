import Foundation

/// Reconstructs each provider's spend onto the **user's local calendar month**, from a
/// stream of the raw month-to-date readings the providers give us.
///
/// ## Why this exists
///
/// We want the combined spend pie to reset on the user's local calendar-month boundary
/// (00:00 local on the 1st). But every provider reports "month-to-date" against *its
/// own* billing cycle, which does not line up with that boundary — guaranteed off by at
/// least a time-zone offset, quite possibly anchored on a different day of the month
/// entirely. So the provider's raw counter measures a different window than the one we
/// display, and we have to translate it, sample by sample.
///
/// ## The model
///
/// Treat a provider's reported MTD as a cumulative counter that climbs with spend and
/// snaps toward 0 at *its* cycle boundary. Per provider we keep an `Entry` and compute:
///
///     monthSpend = completed + max(0, rawProviderCents − carryIn)
///
/// - `carryIn`   — the slice of the provider's *currently reported* MTD that was spent
///                 **before** the current calendar month began. Subtracted out. It is
///                 non-zero only while the provider cycle that straddled the month
///                 boundary is still open; once that cycle resets, its remaining
///                 in-month spend is banked into `completed` and `carryIn` returns to 0.
/// - `completed` — in-month spend from provider cycles that have already **closed**
///                 during this calendar month, frozen at their last pre-reset reading.
///
/// ## Reset detection — the crux
///
/// A "provider reset" (the provider's own cycle rolling over mid-calendar-month) is
/// detected two ways, in priority order:
///   1. **By timestamp** — `cycleResetsAt` changed. Authoritative; used whenever the
///      provider gives us a reset timestamp (Codex, Cursor). Immune to the value-based
///      failure modes below, and immune to downward *corrections* (a refund leaves the
///      cycle key unchanged, so we just let `monthSpend` dip, clamped at ≥0).
///   2. **By value drop** — the raw reading plunged. The ONLY signal available for a
///      provider with no reset timestamp (Claude). A small dip is probably a
///      refund/correction, not a reset. A true monthly reset zeroes the counter, so we
///      require a plunge below `resetDropFraction` of the prior reading before treating
///      a drop as a reset — otherwise a $100→$99 correction would bank $100 into
///      `completed` and then re-add the $99, roughly doubling the figure. A reset that
///      happens while the app is offline and is followed by enough new spend to conceal
///      the drop is inherently undetectable; it can understate the total, but a routine
///      offline gap is not itself evidence of an incorrect figure.
///
/// ## Accepted inaccuracy
///
/// Everything here is sample-based, so it is only ever as accurate as our most recent
/// reading before an event. If the app is asleep/quit across the month boundary, the
/// `carryIn` we capture is stale; we mark that period low-confidence and show how long
/// we were offline. This is a deliberate, user-approved trade-off — see the transparency
/// breakdown in the menu, which shows the raw reading alongside every derived number so
/// any discrepancy is auditable.
@MainActor
final class SpendLedger {
    /// One provider's reconstructed state. Persisted verbatim; also the struct the menu
    /// breakdown reads. `monthSpendCents` is the value the rest of the app should show.
    struct Entry: Codable, Equatable {
        /// Which LOCAL calendar month `carryIn`/`completed` are accumulated for ("2026-07").
        var calendarMonthKey: String
        /// Portion of `rawProviderCents` spent before this calendar month — subtracted.
        var carryInCents: Double
        /// In-month spend from provider cycles that already closed this calendar month.
        var completedCents: Double
        /// The provider's most recent raw month-to-date reading.
        var rawProviderCents: Double
        /// Identity of the provider's current billing cycle (derived from
        /// `cycleResetsAt`); nil when the provider reports no reset timestamp (Claude).
        /// A change here is the authoritative reset signal.
        var cycleKey: String?
        /// The provider's next reset instant, retained for display.
        var cycleResetsAt: Date?
        var lastSampleAt: Date
        var previousSampleAt: Date?
        /// When we last detected a provider cycle reset, and how — for the breakdown.
        var lastResetAt: Date?
        /// true = reset seen via timestamp change; false = inferred from a value drop.
        var lastResetViaTimestamp: Bool?
        /// Set when THIS sample's reconstruction step may be wrong (see the failure modes
        /// above). Transient — recomputed each sample. `confidenceNote` explains it.
        var lowConfidence: Bool
        var confidenceNote: String?
        /// Sticky within the calendar month: set the first time anything makes a sample
        /// uncertain, and cleared only at the next rollover. A mis-detected reset corrupts
        /// the month's figure for the rest of the month, so this keeps warning even after
        /// the transient `lowConfidence` has cleared on a later clean sample. Optional so
        /// older ledger files (written before this field existed) still decode.
        var monthUncertain: Bool?
        var monthUncertainReason: String?

        /// Whether the current calendar month's figure should be presented as uncertain.
        var isMonthUncertain: Bool { monthUncertain ?? false }

        /// Reconstructed spend attributed to the current local calendar month.
        var monthSpendCents: Double { completedCents + max(0, rawProviderCents - carryInCents) }
    }

    /// A sample gap beyond this means the carry-in captured at a local calendar-month
    /// boundary may be stale. ~6× the 5-minute poll.
    nonisolated static let offlineGapThreshold: TimeInterval = 30 * 60

    /// For a timestamp-less provider (Claude): a monthly reset zeroes the counter, so
    /// only a plunge below this fraction of the prior reading counts as a reset. A
    /// smaller dip is treated as a downward correction/refund (no cycle freeze), which
    /// prevents the double-counting a naive "any decrease is a reset" rule would cause.
    nonisolated static let resetDropFraction = 0.5

    private var entries: [ProviderID: Entry]
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.applicationSupport.appendingPathComponent("spend-ledger.json")
        if let raw = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) {
            entries = Dictionary(uniqueKeysWithValues: decoded.compactMap { pair in
                let key = pair.key
                var value = pair.value
                // Older versions marked any long Claude polling gap as uncertain. Those
                // gaps are routine (for example, a sleeping laptop), so retire only that
                // obsolete persisted warning while preserving every other uncertainty.
                if Self.isRetiredMaskedResetWarning(value.monthUncertainReason) {
                    value.monthUncertain = false
                    value.monthUncertainReason = nil
                    value.lowConfidence = false
                    value.confidenceNote = nil
                }
                return ProviderID(rawValue: key).map { ($0, value) }
            })
        } else {
            entries = [:]
        }
    }

    /// The last reconstructed entry for a provider (for display on launch, before any
    /// fresh fetch has been ingested this session). Nil until the provider has reported
    /// spend at least once.
    func entry(_ id: ProviderID) -> Entry? { entries[id] }

    /// Fold a fresh reading into the ledger and return the updated entry. Must be called
    /// **once per new sample, in time order** — the reconstruction is stateful. (On
    /// launch we display `entry(_:)` from disk instead of re-ingesting the cached
    /// snapshot, which would double-count.)
    @discardableResult
    func ingest(_ id: ProviderID, spend: SpendInfo, now: Date = Date()) -> Entry {
        let updated = Self.reconstruct(prior: entries[id], rawCents: spend.usedCents,
                                       cycleResetsAt: spend.cycleResetsAt, now: now)
        entries[id] = updated
        save()
        return updated
    }

    // MARK: - Pure reconstruction (unit-tested directly)

    /// Compute the next `Entry` from the prior one and a fresh reading. Pure and
    /// side-effect-free so the state machine can be exercised in isolation.
    nonisolated static func reconstruct(prior: Entry?, rawCents: Double, cycleResetsAt: Date?,
                                        now: Date, calendar: Calendar = .current) -> Entry {
        let monthKey = Self.monthKey(now, calendar: calendar)
        let cycleKey = cycleResetsAt.map(Self.cycleKey)

        // First reading ever for this provider. Seed carryIn = 0 (a deliberate choice:
        // the alternative, carryIn = current MTD, would zero out real spend already
        // incurred this month). The consequence is that the first partial month may
        // over-count by whatever the provider had accrued before we started watching —
        // accepted, and it self-corrects at the next real reset / month rollover.
        guard let prior else {
            return Entry(calendarMonthKey: monthKey, carryInCents: 0, completedCents: 0,
                         rawProviderCents: rawCents, cycleKey: cycleKey, cycleResetsAt: cycleResetsAt,
                         lastSampleAt: now, previousSampleAt: nil,
                         lastResetAt: nil, lastResetViaTimestamp: nil,
                         lowConfidence: false, confidenceNote: nil,
                         monthUncertain: false, monthUncertainReason: nil)
        }

        let gap = now.timeIntervalSince(prior.lastSampleAt)
        let offline = gap > offlineGapThreshold
        let gapText = UsageMath.formatAgoShort(since: prior.lastSampleAt, now: now)
        let hasTimestamp = cycleKey != nil
        let valueDropped = rawCents < prior.rawProviderCents
        let cycleChanged = hasTimestamp && prior.cycleKey != nil && cycleKey != prior.cycleKey

        // A reset we're willing to ACT on (bank the closed cycle). We require the value to
        // have actually dropped — even when a timestamp says the cycle rolled — so a
        // provider whose counter does NOT zero at its boundary can't trick us into banking
        // the old total and then re-counting the new reading (a ~2× overstatement). A
        // timestamp-less provider (Claude) has only the value to go on, so we demand a
        // plunge below `resetDropFraction`; a smaller dip is a correction, not a reset.
        let confirmedReset: Bool
        if hasTimestamp {
            confirmedReset = cycleChanged && valueDropped
        } else {
            confirmedReset = rawCents < prior.rawProviderCents * resetDropFraction
        }
        // A timestamp says a new cycle began but the value did NOT drop — ambiguous (either
        // the provider doesn't zero at its boundary, or a reset was masked while we were
        // offline). We deliberately don't bank; we only flag the month uncertain.
        let cycleAdvancedWithoutDrop = cycleChanged && !valueDropped

        // --- Case: the user's calendar month rolled over since we last sampled. ---
        // Everything on the provider's clock at the boundary belongs to the previous
        // calendar month, so subtract it via carryIn. Best estimate of "MTD at the
        // boundary" is our last pre-rollover reading. If the provider ALSO reset across
        // the gap (a confirmed reset), that old reading is gone and the fresh cycle is
        // entirely in-month, so carryIn is 0 instead. Stickiness restarts for the new month.
        if monthKey != prior.calendarMonthKey {
            let carryIn = confirmedReset ? 0 : prior.rawProviderCents
            let note = offline
                ? "New month began while offline (\(gapText) since last reading); carry-over estimated from the last reading."
                : nil
            return Entry(calendarMonthKey: monthKey, carryInCents: carryIn, completedCents: 0,
                         rawProviderCents: rawCents, cycleKey: cycleKey, cycleResetsAt: cycleResetsAt,
                         lastSampleAt: now, previousSampleAt: prior.lastSampleAt,
                         lastResetAt: confirmedReset ? now : prior.lastResetAt,
                         lastResetViaTimestamp: confirmedReset ? hasTimestamp : prior.lastResetViaTimestamp,
                         lowConfidence: offline, confidenceNote: note,
                         monthUncertain: offline, monthUncertainReason: note)
        }

        // --- Case: provider cycle reset within the same calendar month (confirmed). ---
        // Bank the just-closed cycle's in-month portion (its final reading minus the part
        // that predated this month), then start the fresh cycle with carryIn = 0.
        if confirmedReset {
            let banked = max(0, prior.rawProviderCents - prior.carryInCents)
            let low = offline || !hasTimestamp
            let note: String?
            if !hasTimestamp {
                note = "Reset inferred from a spend drop (\(gapText) between readings); this provider reports no reset time."
            } else if offline {
                note = "Cycle reset detected after being offline \(gapText)."
            } else {
                note = nil
            }
            return Entry(calendarMonthKey: monthKey, carryInCents: 0,
                         completedCents: prior.completedCents + banked,
                         rawProviderCents: rawCents, cycleKey: cycleKey, cycleResetsAt: cycleResetsAt,
                         lastSampleAt: now, previousSampleAt: prior.lastSampleAt,
                         lastResetAt: now, lastResetViaTimestamp: hasTimestamp,
                         lowConfidence: low, confidenceNote: note,
                         monthUncertain: prior.isMonthUncertain || low,
                         monthUncertainReason: low ? note : prior.monthUncertainReason)
        }

        // --- Case: normal update (same calendar month, no confirmed reset). ---
        // Plain growth — or a small dip we treat as a correction — is captured by the
        // monthSpend formula directly; carryIn/completed are unchanged. A long gap alone
        // is not a warning: a hidden timestamp-less reset can only be inferred from a
        // later drop, and normal sleep should not permanently taint the month. A provider
        // timestamp advancing without a matching value drop remains genuinely ambiguous.
        let thisLow = cycleAdvancedWithoutDrop
        let note: String?
        if cycleAdvancedWithoutDrop {
            note = "Provider signaled a new cycle but its spend didn't drop; not reconciled — the total may be off."
        } else {
            note = nil
        }
        return Entry(calendarMonthKey: monthKey, carryInCents: prior.carryInCents,
                     completedCents: prior.completedCents,
                     rawProviderCents: rawCents, cycleKey: cycleKey ?? prior.cycleKey,
                     cycleResetsAt: cycleResetsAt ?? prior.cycleResetsAt,
                     lastSampleAt: now, previousSampleAt: prior.lastSampleAt,
                     lastResetAt: prior.lastResetAt, lastResetViaTimestamp: prior.lastResetViaTimestamp,
                     lowConfidence: thisLow, confidenceNote: note,
                     monthUncertain: prior.isMonthUncertain || thisLow,
                     monthUncertainReason: thisLow ? note : prior.monthUncertainReason)
    }

    /// Recognizes the persisted warning emitted by versions that treated every long
    /// timestamp-less gap as evidence of a concealed reset. It is intentionally narrow
    /// so migrations never clear a warning caused by an observed event.
    private static func isRetiredMaskedResetWarning(_ note: String?) -> Bool {
        note?.hasSuffix("a reset could have gone unseen (no reset time from this provider).") == true
    }

    /// Local-calendar-month bucket key, e.g. "2026-07". LOCAL by design — the whole point
    /// is to reset on the user's own calendar month, not any provider's or UTC's.
    nonisolated static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Stable identity for a provider billing cycle, from its reset instant. Rounded to
    /// the minute so sub-minute float jitter in the reported timestamp isn't misread as a
    /// new cycle.
    nonisolated static func cycleKey(_ resetsAt: Date) -> String {
        String(Int((resetsAt.timeIntervalSince1970 / 60).rounded()))
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
        guard let raw = try? JSONEncoder().encode(encodable) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }
}
