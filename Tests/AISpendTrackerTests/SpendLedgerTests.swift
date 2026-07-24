import XCTest
@testable import AISpendTracker

/// Exercises the pure `SpendLedger.reconstruct` state machine across every branch:
/// first run, normal growth, mid-month provider resets (timestamp and value-drop),
/// calendar rollover (with and without a coincident provider reset), and the
/// low-confidence flags. All dates use a fixed UTC calendar so month boundaries are
/// deterministic regardless of where the tests run.
final class SpendLedgerTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func reconstruct(_ prior: SpendLedger.Entry?, raw: Double, resets: Date?, now: Date) -> SpendLedger.Entry {
        SpendLedger.reconstruct(prior: prior, rawCents: raw, cycleResetsAt: resets, now: now, calendar: cal)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spend-ledger-test-\(UUID().uuidString).json")
    }

    // MARK: - First run

    func testFirstRunSeedsCarryInZero() {
        let e = reconstruct(nil, raw: 4480, resets: date(2026, 8, 1), now: date(2026, 7, 10, 12))
        XCTAssertEqual(e.carryInCents, 0)                 // decision: seed carryIn = 0
        XCTAssertEqual(e.completedCents, 0)
        XCTAssertEqual(e.monthSpendCents, 4480)           // shows the full provider MTD
        XCTAssertEqual(e.calendarMonthKey, "2026-07")
        XCTAssertFalse(e.lowConfidence)
    }

    // MARK: - Normal growth (same month, same cycle)

    func testNormalGrowthAccumulates() {
        let reset = date(2026, 8, 1)
        let s1 = reconstruct(nil, raw: 100, resets: reset, now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 150, resets: reset, now: date(2026, 7, 10, 12, 5))
        XCTAssertEqual(s2.monthSpendCents, 150)
        XCTAssertEqual(s2.carryInCents, 0)
        XCTAssertEqual(s2.completedCents, 0)
        XCTAssertFalse(s2.lowConfidence)
    }

    /// A reset timestamp that only jitters by seconds is the SAME cycle (keyed to the
    /// minute), so it must not be misread as a reset.
    func testTimestampJitterIsNotAReset() {
        let s1 = reconstruct(nil, raw: 100, resets: date(2026, 8, 1, 0, 0), now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 120, resets: date(2026, 8, 1, 0, 0).addingTimeInterval(12),
                             now: date(2026, 7, 10, 12, 5))
        XCTAssertEqual(s2.completedCents, 0)              // no cycle freeze
        XCTAssertEqual(s2.monthSpendCents, 120)
    }

    // MARK: - Mid-month provider reset

    func testTimestampResetBanksClosedCycle() {
        let s1 = reconstruct(nil, raw: 100, resets: date(2026, 7, 15), now: date(2026, 7, 15, 0, 55))
        let s2 = reconstruct(s1, raw: 10, resets: date(2026, 8, 15), now: date(2026, 7, 15, 1, 0))
        XCTAssertEqual(s2.completedCents, 100)            // closed cycle's in-month portion banked
        XCTAssertEqual(s2.carryInCents, 0)
        XCTAssertEqual(s2.monthSpendCents, 110)           // 100 banked + 10 new
        XCTAssertEqual(s2.lastResetViaTimestamp, true)
        XCTAssertFalse(s2.lowConfidence)                  // timestamped reset is trusted
    }

    /// Claude (no reset timestamp): a plunge past `resetDropFraction` is a reset, and it
    /// is flagged low-confidence because value-drop detection is fallible.
    func testValueDropResetForTimestamplessProvider() {
        let s1 = reconstruct(nil, raw: 100, resets: nil, now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 10, resets: nil, now: date(2026, 7, 15, 12))
        XCTAssertEqual(s2.completedCents, 100)
        XCTAssertEqual(s2.monthSpendCents, 110)
        XCTAssertTrue(s2.lowConfidence)
        XCTAssertTrue(s2.isMonthUncertain)
        XCTAssertNotNil(s2.confidenceNote)
    }

    /// A timestamped provider whose cycle advances but whose counter does NOT drop must
    /// NOT bank the old total (which would ~double the figure). It reads as a normal
    /// update and flags the month uncertain instead. Guards against a provider whose
    /// spend meter doesn't zero at its billing boundary. (concern #1)
    func testTimestampCycleAdvanceWithoutDropIsNotBanked() {
        let s1 = reconstruct(nil, raw: 300, resets: date(2026, 7, 4), now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 320, resets: date(2026, 8, 4), now: date(2026, 7, 10, 12, 5))
        XCTAssertEqual(s2.completedCents, 0)              // nothing banked → no doubling
        XCTAssertEqual(s2.monthSpendCents, 320)           // not 300 + 320
        XCTAssertTrue(s2.isMonthUncertain)
    }

    /// Uncertainty is sticky within a calendar month — it survives later clean samples
    /// (because a mis-detected reset corrupts the whole month), then clears at the next
    /// online rollover.
    func testMonthUncertaintyIsStickyThenClearsAtRollover() {
        let s1 = reconstruct(nil, raw: 100, resets: nil, now: date(2026, 7, 31, 23, 45))
        let s2 = reconstruct(s1, raw: 10, resets: nil, now: date(2026, 7, 31, 23, 50))   // value-drop reset
        XCTAssertTrue(s2.isMonthUncertain)
        let s3 = reconstruct(s2, raw: 12, resets: nil, now: date(2026, 7, 31, 23, 55))   // clean sample
        XCTAssertFalse(s3.lowConfidence)                  // this sample alone is fine
        XCTAssertTrue(s3.isMonthUncertain)                // but the month stays flagged
        let s4 = reconstruct(s3, raw: 15, resets: nil, now: date(2026, 8, 1, 0, 0))      // online rollover
        XCTAssertFalse(s4.isMonthUncertain)               // cleared for the new month
    }

    /// A small downward correction (refund) on a timestamp-less provider must NOT be
    /// treated as a reset — doing so would double-count. It reads as a normal update.
    func testSmallDropIsCorrectionNotReset() {
        let s1 = reconstruct(nil, raw: 100, resets: nil, now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 99, resets: nil, now: date(2026, 7, 10, 12, 5))
        XCTAssertEqual(s2.completedCents, 0)              // no freeze
        XCTAssertEqual(s2.monthSpendCents, 99)
    }

    /// A downward correction on a TIMESTAMPED provider (cycle unchanged) also isn't a
    /// reset — monthSpend just dips, clamped at ≥0.
    func testTimestampedCorrectionClampsAtZero() {
        let reset = date(2026, 8, 1)
        let s1 = reconstruct(nil, raw: 100, resets: reset, now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 40, resets: reset, now: date(2026, 7, 10, 12, 5))
        XCTAssertEqual(s2.completedCents, 0)
        XCTAssertEqual(s2.monthSpendCents, 40)
    }

    // MARK: - Calendar rollover

    func testCalendarRolloverSubtractsPreMonthPortion() {
        let reset = date(2026, 8, 20)                     // provider cycle spans the calendar boundary
        let s1 = reconstruct(nil, raw: 110, resets: reset, now: date(2026, 7, 31, 23, 55))
        let s2 = reconstruct(s1, raw: 130, resets: reset, now: date(2026, 8, 1, 0, 5))
        XCTAssertEqual(s2.calendarMonthKey, "2026-08")
        XCTAssertEqual(s2.carryInCents, 110)              // pre-August spend subtracted
        XCTAssertEqual(s2.completedCents, 0)
        XCTAssertEqual(s2.monthSpendCents, 20)            // only the August delta
    }

    func testCalendarRolloverWithCoincidentProviderReset() {
        let s1 = reconstruct(nil, raw: 110, resets: date(2026, 7, 31), now: date(2026, 7, 31, 23, 50))
        let s2 = reconstruct(s1, raw: 5, resets: date(2026, 8, 31), now: date(2026, 8, 1, 0, 5))
        XCTAssertEqual(s2.calendarMonthKey, "2026-08")
        XCTAssertEqual(s2.carryInCents, 0)                // fresh cycle is wholly in-month
        XCTAssertEqual(s2.monthSpendCents, 5)
    }

    // MARK: - Confidence flags

    func testRolloverWhileOfflineIsLowConfidence() {
        let reset = date(2026, 8, 20)
        let s1 = reconstruct(nil, raw: 110, resets: reset, now: date(2026, 7, 31, 12))
        let s2 = reconstruct(s1, raw: 130, resets: reset, now: date(2026, 8, 1, 9))   // ~21h gap
        XCTAssertTrue(s2.lowConfidence)
        XCTAssertNotNil(s2.confidenceNote)
    }

    func testTimestamplessLongGapWithoutObservedDropIsConfident() {
        let s1 = reconstruct(nil, raw: 100, resets: nil, now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 100, resets: nil, now: date(2026, 7, 10, 13))   // 1h gap, no visible drop
        XCTAssertFalse(s2.lowConfidence)
        XCTAssertFalse(s2.isMonthUncertain)
        XCTAssertEqual(s2.monthSpendCents, 100)
    }

    @MainActor
    func testLoadingRetiresOnlyTheObsoleteMaskedResetWarning() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let now = date(2026, 7, 10, 12)
        let obsoleteClaude = SpendLedger.Entry(
            calendarMonthKey: "2026-07", carryInCents: 0, completedCents: 0,
            rawProviderCents: 48616, cycleKey: nil, cycleResetsAt: nil,
            lastSampleAt: now, previousSampleAt: nil, lastResetAt: nil,
            lastResetViaTimestamp: nil, lowConfidence: false, confidenceNote: nil,
            monthUncertain: true,
            monthUncertainReason: "Offline 6h; a reset could have gone unseen (no reset time from this provider).")
        let untouchedCodex = SpendLedger.Entry(
            calendarMonthKey: "2026-07", carryInCents: 25, completedCents: 10,
            rawProviderCents: 75, cycleKey: "123", cycleResetsAt: now,
            lastSampleAt: now, previousSampleAt: nil, lastResetAt: nil,
            lastResetViaTimestamp: nil, lowConfidence: false, confidenceNote: nil,
            monthUncertain: false, monthUncertainReason: nil)
        try JSONEncoder().encode(["claude": obsoleteClaude, "codex": untouchedCodex]).write(to: url)

        let ledger = SpendLedger(fileURL: url)
        XCTAssertFalse(ledger.entry(.claude)!.isMonthUncertain)
        XCTAssertEqual(ledger.entry(.codex), untouchedCodex)

        let persisted = try JSONDecoder().decode([String: SpendLedger.Entry].self,
                                                  from: Data(contentsOf: url))
        XCTAssertFalse(persisted["claude"]!.isMonthUncertain)
        XCTAssertNil(persisted["claude"]!.monthUncertainReason)
        XCTAssertEqual(persisted["codex"], untouchedCodex)
    }

    /// A timestamped provider with a long gap and no reset is NOT low-confidence — any
    /// reset would have surfaced as a cycle-key change.
    func testTimestampedLongGapNoResetIsConfident() {
        let reset = date(2026, 8, 1)
        let s1 = reconstruct(nil, raw: 100, resets: reset, now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 130, resets: reset, now: date(2026, 7, 10, 16))   // 4h gap
        XCTAssertFalse(s2.lowConfidence)
        XCTAssertEqual(s2.monthSpendCents, 130)
    }

    /// $0 → $0 across a would-be reset is benign: no drop, nothing to misattribute.
    func testZeroSpendStaysZero() {
        let s1 = reconstruct(nil, raw: 0, resets: nil, now: date(2026, 7, 10, 12))
        let s2 = reconstruct(s1, raw: 0, resets: nil, now: date(2026, 7, 10, 12, 5))
        XCTAssertEqual(s2.monthSpendCents, 0)
        XCTAssertFalse(s2.lowConfidence)
    }

    // MARK: - Helpers

    func testMonthKeyIsLocalCalendarMonth() {
        XCTAssertEqual(SpendLedger.monthKey(date(2026, 7, 1), calendar: cal), "2026-07")
        XCTAssertEqual(SpendLedger.monthKey(date(2026, 12, 31, 23, 59), calendar: cal), "2026-12")
    }
}
