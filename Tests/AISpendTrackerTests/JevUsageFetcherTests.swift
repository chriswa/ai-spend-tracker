import XCTest
@testable import AISpendTracker

final class JevUsageFetcherTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func run(_ stdout: String, status: Int32 = 0, seconds: Double = 0.05) -> JevUsageFetcher.Run {
        JevUsageFetcher.Run(stdout: stdout, stderr: "", status: status, duration: .milliseconds(Int(seconds * 1000)))
    }

    /// Dollars on stdout → spend-only snapshot flagged as the local calendar month,
    /// with the cycle ending at the start of next month.
    func testParsesDollarsAsCalendarMonthSpend() throws {
        let snap = try JevUsageFetcher.snapshot(from: run("12.345\n"), startedAt: date(2026, 9, 25, 10), calendar: cal)
        XCTAssertTrue(snap.windows.isEmpty)
        XCTAssertNil(snap.warning)
        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.usedCents, 1234.5, accuracy: 1e-9)
        XCTAssertEqual(spend.isLocalCalendarMonth, true)
        XCTAssertEqual(spend.cycleResetsAt, date(2026, 10, 1))
    }

    func testSlowRunWarnsButKeepsData() throws {
        let snap = try JevUsageFetcher.snapshot(from: run("1.5", seconds: 3.4), startedAt: date(2026, 9, 25), calendar: cal)
        XCTAssertEqual(snap.spend?.usedCents ?? 0, 150, accuracy: 1e-9)
        XCTAssertEqual(snap.warning, "jev --mtd took 3.4s (over 2.0s) — optimize its aggregation")
    }

    func testNonZeroExitFails() {
        XCTAssertThrowsError(try JevUsageFetcher.snapshot(from: run("", status: 1), startedAt: Date(), calendar: cal)) {
            XCTAssertEqual(JevUsageFetcher().classify($0), "jev --mtd exited with status 1")
        }
    }

    func testGarbageOutputFails() {
        XCTAssertThrowsError(try JevUsageFetcher.snapshot(from: run("oops"), startedAt: Date(), calendar: cal)) {
            XCTAssertEqual(JevUsageFetcher().classify($0), "Couldn't parse jev --mtd output")
        }
    }

    /// A run that crosses into a new month is repeated so the reading can't be last
    /// month's total attributed to this month.
    func testRunStraddlingMonthBoundaryIsRepeated() throws {
        final class State: @unchecked Sendable { var clock: [Date] = []; var runs = 0 }
        let state = State()
        state.clock = [date(2026, 9, 30, 23, 59), date(2026, 10, 1, 0, 0), date(2026, 10, 1, 0, 0)]
        let fetcher = JevUsageFetcher(
            runner: { state.runs += 1; return JevUsageFetcher.Run(stdout: state.runs == 1 ? "50" : "0.01", stderr: "",
                                                                 status: 0, duration: .zero) },
            now: { state.clock.removeFirst() }, calendar: cal)
        let result = try fetcher.fetchBlocking()
        XCTAssertEqual(state.runs, 2)
        XCTAssertEqual(result.snapshot.spend?.usedCents ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(result.snapshot.spend?.cycleResetsAt, date(2026, 11, 1))
    }
}
