import XCTest
@testable import AISpendTracker

/// Locks in multi-account tracking: each account's last reading is kept in the order it
/// was first detected, inactive accounts are carried forward assuming no use, the active
/// account is the one marked for underlining, and spend is kept per account.
@MainActor
final class AccountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let team = AccountRef(id: "org-team", label: "Spare")
    private let personal = AccountRef(id: "org-personal", label: "Personal")

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cut-account-test-\(UUID().uuidString).json")
    }

    private func snapshot(_ account: AccountRef?, fiveHour: Double, resetsIn: TimeInterval,
                          spendCents: Double? = nil) -> ProviderSnapshot {
        ProviderSnapshot(windows: [
            UsageWindow(caption: "5-Hour", utilization: fiveHour, resetsAt: now.addingTimeInterval(resetsIn),
                        timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
        ], spend: spendCents.map { SpendInfo(usedCents: $0, apiLimitCents: nil, label: "Claude extra usage") },
           account: account)
    }

    // MARK: - Store

    func testAccountsKeepFirstDetectedOrderAcrossSwitches() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStore(fileURL: url)
        store.saveSnapshot(.claude, snapshot(team, fiveHour: 100, resetsIn: 3600), at: now)
        store.saveSnapshot(.claude, snapshot(personal, fiveHour: 8, resetsIn: 3600), at: now.addingTimeInterval(60))
        store.saveSnapshot(.claude, snapshot(team, fiveHour: 20, resetsIn: 3600), at: now.addingTimeInterval(120))

        let readings = UsageStore(fileURL: url).accountReadings(.claude)
        XCTAssertEqual(readings.map(\.account), [team, personal], "switching back must not reorder")
        XCTAssertEqual(readings[0].snapshot.windows[0].utilization, 20)
        XCTAssertEqual(readings[1].snapshot.windows[0].utilization, 8)
        XCTAssertEqual(store.snapshot(.claude)?.account, team, "the latest reading is the active one")
    }

    func testUnidentifiedReadingIsReplacedByTheFirstIdentifiedOne() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStore(fileURL: url)
        store.saveSnapshot(.claude, snapshot(nil, fiveHour: 50, resetsIn: 3600), at: now)
        store.saveSnapshot(.claude, snapshot(personal, fiveHour: 8, resetsIn: 3600), at: now)
        XCTAssertEqual(store.accountReadings(.claude).map(\.account), [personal])
    }

    // MARK: - Carry-forward

    func testInactiveWindowHoldsUntilResetThenReadsIdle() {
        let w = UsageWindow(caption: "5-Hour", utilization: 100, resetsAt: now,
                            timeBasis: .rollingWindow(length: WindowLength.fiveHour))
        XCTAssertEqual(w.assumingNoUseSince(now: now.addingTimeInterval(-1)), w)
        let idle = w.assumingNoUseSince(now: now)
        XCTAssertEqual(idle.utilization, 0)
        XCTAssertNil(idle.resetsAt)
    }

    func testCirclesShowEveryAccountInOrderAndMarkOnlyTheActiveOne() {
        let claude = ProviderView(id: .claude, displayName: "Claude", accounts: [
            AccountView(account: team, snapshot: snapshot(team, fiveHour: 100, resetsIn: -60),
                        lastUpdated: now.addingTimeInterval(-5 * 3600), isActive: false),
            AccountView(account: personal, snapshot: snapshot(personal, fiveHour: 8, resetsIn: 3600),
                        lastUpdated: now, isActive: true),
        ])
        let circles = PieChart.circles(from: TrayViewModel(providers: [claude], customLimitCents: 0), now: now)
        XCTAssertEqual(circles.map(\.accountLabel), ["Spare", "Personal"])
        XCTAssertEqual(circles.map(\.marksActiveAccount), [false, true])
        XCTAssertEqual(circles.map(\.startsGroup), [true, true])
        // The team window's reset has passed, so it reads as an idle, empty window.
        XCTAssertEqual(circles[0].kind, .pie(time: 0, usage: 0))
    }

    func testSingleAccountIsNotMarked() {
        let claude = ProviderView(id: .claude, displayName: "Claude",
                                  snapshot: snapshot(personal, fiveHour: 8, resetsIn: 3600), lastUpdated: now)
        let circles = PieChart.circles(from: TrayViewModel(providers: [claude], customLimitCents: 0), now: now)
        XCTAssertEqual(circles.map(\.marksActiveAccount), [false])
        XCTAssertEqual(circles.map(\.accountLabel), ["Personal"])
    }

    func testErrorOnlyReplacesTheActiveAccount() {
        let claude = ProviderView(id: .claude, displayName: "Claude", error: "Usage API 500", accounts: [
            AccountView(account: team, snapshot: snapshot(team, fiveHour: 100, resetsIn: 3600),
                        lastUpdated: now, isActive: false),
            AccountView(account: personal, snapshot: snapshot(personal, fiveHour: 8, resetsIn: 3600),
                        lastUpdated: now, isActive: true),
        ])
        let circles = PieChart.circles(from: TrayViewModel(providers: [claude], customLimitCents: 0), now: now)
        XCTAssertEqual(circles.count, 2)
        XCTAssertNotEqual(circles[0].kind, .error)
        XCTAssertEqual(circles[1].kind, .error)
    }

    // MARK: - Spend

    func testLedgerKeepsAccountsApartAndTheTotalSumsThem() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let ledger = SpendLedger(fileURL: url)
        let spend = { (c: Double) in SpendInfo(usedCents: c, apiLimitCents: nil, label: "Claude extra usage") }
        ledger.ingest(.claude, account: team, spend: spend(2122), now: now)
        // Switching to an account with no spend must not read as the team cycle resetting.
        ledger.ingest(.claude, account: personal, spend: spend(0), now: now.addingTimeInterval(60))
        ledger.ingest(.claude, account: team, spend: spend(2200), now: now.addingTimeInterval(120))
        XCTAssertEqual(ledger.entry(.claude, account: team)?.monthSpendCents, 2200)
        XCTAssertEqual(ledger.entry(.claude, account: team)?.completedCents, 0)

        let claude = ProviderView(id: .claude, displayName: "Claude", accounts: [
            AccountView(account: team, snapshot: snapshot(team, fiveHour: 0, resetsIn: 3600, spendCents: 2200),
                        lastUpdated: now, isActive: true,
                        reconstructedSpend: ledger.entry(.claude, account: team)),
            AccountView(account: personal, snapshot: snapshot(personal, fiveHour: 0, resetsIn: 3600, spendCents: 500),
                        lastUpdated: now, isActive: false),
        ])
        XCTAssertEqual(TrayViewModel(providers: [claude], customLimitCents: 0).combinedSpendCents, 2700)
    }

    // MARK: - Claude account detection

    func testClaudeAccountIsKeyedByOrganizationAndPersonalOrgsAreLabeledPersonal() {
        func parse(_ name: String) -> AccountRef? {
            let json = #"{"oauthAccount": {"organizationUuid": "org-1", "organizationName": "\#(name)"}}"#
            return ClaudeUsageFetcher.parseAccount(fromClaudeConfig: Data(json.utf8))
        }
        XCTAssertEqual(parse("Spare"), AccountRef(id: "org-1", label: "Spare"))
        XCTAssertEqual(parse("someone@example.com's Organization"), AccountRef(id: "org-1", label: "Personal"))
        XCTAssertNil(ClaudeUsageFetcher.parseAccount(fromClaudeConfig: Data("{}".utf8)))
    }

    func testHiddenScopedWindowDrawsNoCircle() {
        var snap = snapshot(personal, fiveHour: 8, resetsIn: 3600)
        snap.windows.append(UsageWindow(caption: "Fable 7-Day", utilization: 5, resetsAt: now.addingTimeInterval(3600),
                                        timeBasis: .rollingWindow(length: WindowLength.sevenDay), isScoped: true))
        let claude = ProviderView(id: .claude, displayName: "Claude", snapshot: snap, lastUpdated: now)
        var vm = TrayViewModel(providers: [claude], customLimitCents: 0)
        XCTAssertEqual(vm.scopedWindowCaptions, ["Fable 7-Day"])
        XCTAssertEqual(PieChart.circles(from: vm, now: now).map(\.caption), ["5-Hour", "Fable 7-Day"])
        vm.hiddenScopedWindows = ["Fable 7-Day"]
        XCTAssertEqual(PieChart.circles(from: vm, now: now).map(\.caption), ["5-Hour"])
    }
}
