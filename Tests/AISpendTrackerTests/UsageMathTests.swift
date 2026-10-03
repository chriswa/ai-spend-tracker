import XCTest
@testable import AISpendTracker

final class UsageMathTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func rolling(_ util: Double, resetsIn: TimeInterval, length: TimeInterval,
                         projects: Bool = true) -> UsageWindow {
        UsageWindow(caption: "w", utilization: util, resetsAt: now.addingTimeInterval(resetsIn),
                    timeBasis: .rollingWindow(length: length), supportsProjection: projects)
    }

    func testFormatAgoShort() {
        func ago(_ seconds: TimeInterval) -> String {
            UsageMath.formatAgoShort(since: now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(ago(0), "0s")
        XCTAssertEqual(ago(47), "47s")
        XCTAssertEqual(ago(59), "59s")
        XCTAssertEqual(ago(60), "1m")
        XCTAssertEqual(ago(3 * 60 + 30), "3m")      // truncates to whole minutes
        XCTAssertEqual(ago(59 * 60), "59m")
        XCTAssertEqual(ago(2 * 3600 + 5 * 60), "2h")
        XCTAssertEqual(ago(25 * 3600), "1d")
        // A clock that briefly reads behind the fetch time never shows a negative age.
        XCTAssertEqual(UsageMath.formatAgoShort(since: now.addingTimeInterval(30), now: now), "0s")
    }

    func testTimeFractionMidWindow() {
        // 2h remaining in a 5h window → 3h elapsed → 60%.
        let resets = now.addingTimeInterval(2 * 3600)
        let f = UsageMath.timeFraction(.rollingWindow(length: WindowLength.fiveHour), resetsAt: resets, now: now)
        XCTAssertEqual(f, 0.6, accuracy: 1e-9)
    }

    func testTimeFractionClampsBothEnds() {
        XCTAssertEqual(UsageMath.timeFraction(.rollingWindow(length: WindowLength.fiveHour),
                                              resetsAt: now.addingTimeInterval(-60), now: now), 1)
        XCTAssertEqual(UsageMath.timeFraction(.rollingWindow(length: WindowLength.fiveHour),
                                              resetsAt: now.addingTimeInterval(WindowLength.fiveHour + 60), now: now), 0)
    }

    func testTimeFractionInterval() {
        // Halfway through an explicit start…end span → 50%.
        let start = now.addingTimeInterval(-3600)
        let end = now.addingTimeInterval(3600)
        XCTAssertEqual(UsageMath.timeFraction(.interval(start: start, end: end), resetsAt: end, now: now),
                       0.5, accuracy: 1e-9)
    }

    func testTimeFractionNoneIsZero() {
        XCTAssertEqual(UsageMath.timeFraction(.none, resetsAt: nil, now: now), 0)
    }

    func testUsageFraction() {
        XCTAssertEqual(UsageMath.usageFraction(utilization: 45), 0.45, accuracy: 1e-9)
        XCTAssertEqual(UsageMath.usageFraction(utilization: 130), 1.3, accuracy: 1e-9)   // not clamped above 1
        XCTAssertEqual(UsageMath.usageFraction(utilization: -5), 0)                      // floored at 0
    }

    func testProjectionExtrapolatesLinearly() {
        // 60% elapsed, 45% used → projected 45 / 0.6 = 75%.
        let proj = UsageMath.projectUsage(rolling(45, resetsIn: 2 * 3600, length: WindowLength.fiveHour), now: now)
        XCTAssertEqual(try XCTUnwrap(proj), 75, accuracy: 1e-6)
    }

    func testProjectionOnInterval() {
        // Halfway through the month, 20% used → ~40%.
        let start = now.addingTimeInterval(-15 * 24 * 3600)
        let end = now.addingTimeInterval(15 * 24 * 3600)
        let w = UsageWindow(caption: "Monthly", utilization: 20, resetsAt: end,
                            timeBasis: .interval(start: start, end: end))
        XCTAssertEqual(try XCTUnwrap(UsageMath.projectUsage(w, now: now)), 40, accuracy: 1e-6)
    }

    func testProjectionCanExceed100() {
        let proj = UsageMath.projectUsage(rolling(50, resetsIn: 5 * 24 * 3600, length: WindowLength.sevenDay), now: now)
        XCTAssertGreaterThan(try XCTUnwrap(proj), 100)
    }

    func testProjectionNilWhenTooEarly() {
        // Only 5 min elapsed (< 10 min threshold).
        XCTAssertNil(UsageMath.projectUsage(
            rolling(5, resetsIn: WindowLength.fiveHour - 5 * 60, length: WindowLength.fiveHour), now: now))
    }

    func testProjectionNilWhenExpiredZeroOrUnsupported() {
        XCTAssertNil(UsageMath.projectUsage(rolling(40, resetsIn: -1, length: WindowLength.fiveHour), now: now))
        XCTAssertNil(UsageMath.projectUsage(rolling(0, resetsIn: 2 * 3600, length: WindowLength.fiveHour), now: now))
        XCTAssertNil(UsageMath.projectUsage(
            rolling(45, resetsIn: 2 * 3600, length: WindowLength.fiveHour, projects: false), now: now))
    }

    func testMonthTimeFraction() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midJuly = cal.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 0))!
        XCTAssertEqual(UsageMath.monthTimeFraction(now: midJuly, calendar: cal), 15.0 / 31.0, accuracy: 1e-9)
        let start = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 0))!
        XCTAssertEqual(UsageMath.monthTimeFraction(now: start, calendar: cal), 0, accuracy: 1e-9)
    }

    func testSpendFraction() {
        XCTAssertEqual(UsageMath.spendFraction(usedCents: 24955, limitCents: 50000), 0.4991, accuracy: 1e-9)
        XCTAssertEqual(UsageMath.spendFraction(usedCents: 60000, limitCents: 50000), 1.2, accuracy: 1e-9)   // not clamped above 1
        // No budget → binary ring: empty at $0, full above.
        XCTAssertEqual(UsageMath.spendFraction(usedCents: 0, limitCents: 0), 0)
        XCTAssertEqual(UsageMath.spendFraction(usedCents: 100, limitCents: 0), 1)
    }

    func testUsageRatePoints() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [(Date, Double)] = [
            (t, 10),
            (t.addingTimeInterval(5 * 60), 20),
            (t.addingTimeInterval(10 * 60), 5),
            (t.addingTimeInterval(20 * 60), 9),
        ]
        let pts = UsageMath.usageRatePoints(samples)
        XCTAssertEqual(pts.map { $0.0 }, samples.map { $0.0 })
        XCTAssertEqual(pts.map { $0.1 }, [0, 2, 0, 0.4])
    }

    func testPeakRatePerMinute() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let points: [(Date, Double)] = [
            (t, 10),
            (t.addingTimeInterval(5 * 60), 11),
            (t.addingTimeInterval(10 * 60), 14),
            (t.addingTimeInterval(15 * 60), 2),
        ]
        let peak = UsageMath.peakRatePerMinute(points)
        XCTAssertEqual(peak?.perMinute ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(peak?.at, t.addingTimeInterval(10 * 60))
    }

    func testPeakRateNilWhenNoUsage() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(UsageMath.peakRatePerMinute([(t, 5), (t.addingTimeInterval(300), 5),
                                                  (t.addingTimeInterval(600), 0)]))
    }

    func testTrimmed() {
        XCTAssertEqual(UsageMath.trimmed(0.5000121, maxFractionDigits: 2), "0.5")
        XCTAssertEqual(UsageMath.trimmed(1.0, maxFractionDigits: 2), "1")
        XCTAssertEqual(UsageMath.trimmed(0.333333, maxFractionDigits: 2), "0.33")
    }

    func testFormatDelta() {
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(48 * 60), now: now), "48m")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now), "2h 5m")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(3 * 3600), now: now), "3h")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(25 * 3600 + 50 * 60), now: now), "1d 1h")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(48 * 3600), now: now), "2d")
    }

    func testFormatDollarsExact() {
        // jev --mtd's 0.000012138, as the fetcher stores it (dollars × 100).
        XCTAssertEqual(UsageMath.formatDollarsExact(0.000012138 * 100), "$0.000012138")
        XCTAssertEqual(UsageMath.formatDollarsExact(0.4), "$0.004")
    }
}
