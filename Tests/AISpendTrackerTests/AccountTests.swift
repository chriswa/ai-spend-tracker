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

    func testCirclesShowEveryAccountInOrderAndFlagTheInactiveOnes() {
        let claude = ProviderView(id: .claude, displayName: "Claude", accounts: [
            AccountView(account: team, snapshot: snapshot(team, fiveHour: 100, resetsIn: -60),
                        lastUpdated: now.addingTimeInterval(-5 * 3600), isActive: false),
            AccountView(account: personal, snapshot: snapshot(personal, fiveHour: 8, resetsIn: 3600),
                        lastUpdated: now, isActive: true),
        ])
        let circles = PieChart.circles(from: TrayViewModel(providers: [claude], customLimitCents: 0), now: now)
        XCTAssertEqual(circles.map(\.accountLabel), ["Spare", "Personal"])
        XCTAssertEqual(circles.map(\.isInactiveAccount), [true, false])
        let brand = PieChart.palette(for: .claude)
        XCTAssertEqual(circles[0].usageColor, brand.usage, "stripes go over the unaltered colors")
        XCTAssertEqual(circles[0].headingColor, PieChart.grayed(brand.usage))
        XCTAssertEqual(circles[0].overColor, .white, "the maxed-out mark stays pure white")
        XCTAssertEqual(circles[1].usageColor, brand.usage)
        XCTAssertEqual(circles.map(\.startsGroup), [true, true])
        // The team window's reset has passed, so it reads as an idle, empty window.
        XCTAssertEqual(circles[0].kind, .pie(time: 0, usage: 0))
    }

    func testGrayingMixesHalfWithMiddleGrayInOKLabAndKeepsAlpha() {
        func assertMix(_ rgb: [CGFloat], _ expected: [CGFloat], file: StaticString = #filePath, line: UInt = #line) {
            let c = PieChart.grayed(NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 0.4))
            XCTAssertEqual(c.redComponent * 255, expected[0], accuracy: 1, file: file, line: line)
            XCTAssertEqual(c.greenComponent * 255, expected[1], accuracy: 1, file: file, line: line)
            XCTAssertEqual(c.blueComponent * 255, expected[2], accuracy: 1, file: file, line: line)
            XCTAssertEqual(c.alphaComponent, 0.4, accuracy: 0.001, file: file, line: line)
        }
        assertMix([224, 168, 46], [175, 149, 101])   // Fable gold
        assertMix([217, 119, 87], [174, 125, 110])   // Claude orange
        assertMix([127.5, 127.5, 127.5], [127.5, 127.5, 127.5])   // gray is its own mix
    }

    func testSingleAccountIsNotInactive() {
        let claude = ProviderView(id: .claude, displayName: "Claude",
                                  snapshot: snapshot(personal, fiveHour: 8, resetsIn: 3600), lastUpdated: now)
        let circles = PieChart.circles(from: TrayViewModel(providers: [claude], customLimitCents: 0), now: now)
        XCTAssertEqual(circles.map(\.isInactiveAccount), [false])
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

    func testClaudeAccountIsKeyedByOrganizationAndPersonalOrgsAreLabeledByEmailDomain() {
        func parse(_ name: String, email: String? = "someone@example.com") -> AccountRef? {
            let emailField = email.map { #", "email": "\#($0)""# } ?? ""
            let json = #"{"account": {"uuid": "user-1"\#(emailField)}, "organization": {"uuid": "org-1", "name": "\#(name)"}}"#
            return ClaudeUsageFetcher.parseAccount(fromProfile: Data(json.utf8))
        }
        XCTAssertEqual(parse("Spare"), AccountRef(id: "org-1", label: "Spare"))
        XCTAssertEqual(parse("someone@example.com's Organization"), AccountRef(id: "org-1", label: "@example.com"))
        XCTAssertEqual(parse("someone@example.com's Organization", email: nil), AccountRef(id: "org-1", label: "Personal"))
        XCTAssertEqual(parse("someone's Organization", email: "no-domain"), AccountRef(id: "org-1", label: "Personal"))
        XCTAssertEqual(parse("someone's Organization", email: "someone@"), AccountRef(id: "org-1", label: "Personal"))
        XCTAssertNil(ClaudeUsageFetcher.parseAccount(fromProfile: Data("{}".utf8)))
    }

    private func snapshotWithFable(_ account: AccountRef) -> ProviderSnapshot {
        var snap = snapshot(account, fiveHour: 8, resetsIn: 3600)
        snap.windows.append(UsageWindow(caption: "Fable 7-Day", utilization: 5, resetsAt: now.addingTimeInterval(3600),
                                        timeBasis: .rollingWindow(length: WindowLength.sevenDay), isScoped: true))
        return snap
    }

    func testHidingAScopedWindowOnlyAffectsThatAccount() {
        let claude = ProviderView(id: .claude, displayName: "Claude", accounts: [
            AccountView(account: team, snapshot: snapshotWithFable(team), lastUpdated: now, isActive: false),
            AccountView(account: personal, snapshot: snapshotWithFable(personal), lastUpdated: now, isActive: true),
        ])
        var vm = TrayViewModel(providers: [claude], customLimitCents: 0)
        XCTAssertEqual(vm.scopedWindowToggles.map(\.title),
                       ["Show Fable 7-Day (Spare)", "Show Fable 7-Day (Personal)"])

        vm.hiddenScopedWindows.set(true, caption: "Fable 7-Day", account: team)
        let shown = PieChart.circles(from: vm, now: now).map { "\($0.accountLabel ?? "") \($0.caption)" }
        XCTAssertEqual(shown, ["Spare 5-Hour", "Personal 5-Hour", "Personal Fable 7-Day"])

        vm.hiddenScopedWindows.set(false, caption: "Fable 7-Day", account: team)
        XCTAssertEqual(vm.hiddenScopedWindows, HiddenScopedWindows())
    }

    func testScopedWindowToggleOmitsTheAccountWhenThereIsOnlyOne() {
        let claude = ProviderView(id: .claude, displayName: "Claude", snapshot: snapshotWithFable(personal), lastUpdated: now)
        let vm = TrayViewModel(providers: [claude], customLimitCents: 0)
        XCTAssertEqual(vm.scopedWindowToggles.map(\.title), ["Show Fable 7-Day"])
    }
}
