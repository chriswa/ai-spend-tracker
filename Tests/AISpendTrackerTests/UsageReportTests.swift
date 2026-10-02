import XCTest
@testable import AISpendTracker

final class UsageReportTests: XCTestCase {
    func testReportMirrorsMenuReadings() throws {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageWindow(caption: "5-Hour", utilization: 40,
                                 resetsAt: fetched.addingTimeInterval(WindowLength.fiveHour / 2),
                                 timeBasis: .rollingWindow(length: WindowLength.fiveHour))
        let claude = ProviderView(id: .claude, displayName: "Claude",
                                  snapshot: ProviderSnapshot(windows: [window],
                                                             spend: SpendInfo(usedCents: 5_000, apiLimitCents: nil, label: "Claude extra usage")),
                                  lastUpdated: fetched)
        let codex = ProviderView(id: .codex, displayName: "Codex", error: "token expired")
        let vm = TrayViewModel(providers: [claude, codex], customLimitCents: 20_000)

        let report = UsageReport.build(from: vm, now: fetched.addingTimeInterval(600))

        let w = try XCTUnwrap(report.providers.first?.windows.first)
        XCTAssertEqual(w.usagePercent, 40)
        XCTAssertEqual(w.elapsedPercent, 50)            // measured at the fetch, like the menu
        XCTAssertEqual(w.projectedUsagePercent, 80)
        XCTAssertEqual(report.providers.first?.spend?.monthToDateUSD, 50)
        XCTAssertEqual(report.providers.last?.error, "token expired")
        XCTAssertEqual(report.spend?.monthToDateUSD, 50)
        XCTAssertEqual(report.spend?.percentOfBudget, 25)

        let json = try XCTUnwrap(String(data: UsageReport.encode(report), encoding: .utf8))
        XCTAssertFalse(json.contains("812"), "dates must not use Swift's reference-date encoding")
    }
}
