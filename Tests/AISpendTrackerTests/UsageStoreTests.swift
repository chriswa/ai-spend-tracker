import XCTest
@testable import AISpendTracker

@MainActor
final class UsageStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cut-store-test-\(UUID().uuidString).json")
    }

    func testPerProviderRoundTrip() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let store = UsageStore(fileURL: url)
            store.recordAttempt(.codex, at: at)
            store.saveSnapshot(.codex, ProviderSnapshot(windows: [
                UsageWindow(caption: "Weekly", utilization: 30, resetsAt: at,
                            timeBasis: .rollingWindow(length: WindowLength.sevenDay))]), at: at)
            // Claude untouched — providers are independent.
            XCTAssertNil(store.snapshot(.claude))
        }
        let reopened = UsageStore(fileURL: url)
        XCTAssertEqual(reopened.lastFetchAt(.codex)?.timeIntervalSinceReferenceDate ?? 0,
                       at.timeIntervalSinceReferenceDate, accuracy: 1e-6)
        XCTAssertEqual(reopened.lastSuccessAt(.codex)?.timeIntervalSinceReferenceDate ?? 0,
                       at.timeIntervalSinceReferenceDate, accuracy: 1e-6)
        XCTAssertEqual(reopened.snapshot(.codex)?.windows.first?.caption, "Weekly")
        XCTAssertNil(reopened.lastError(.codex))
        XCTAssertNil(reopened.lastFetchAt(.cursor))
    }

    /// A failed attempt after a success is restored as: stale snapshot + last-success
    /// time (never the failed-attempt time) + the error message. This is the state that
    /// makes a restart show the provider as stale rather than falsely healthy/fresh.
    func testErrorOverStaleSnapshotSurvivesRestart() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let success = Date(timeIntervalSince1970: 1_800_000_000)
        let failAttempt = success.addingTimeInterval(3600)
        do {
            let store = UsageStore(fileURL: url)
            store.recordAttempt(.codex, at: success)
            store.saveSnapshot(.codex, ProviderSnapshot(windows: [
                UsageWindow(caption: "Weekly", utilization: 30, resetsAt: success,
                            timeBasis: .rollingWindow(length: WindowLength.sevenDay))]), at: success)
            // A later attempt fails: the attempt clock advances, the data does not.
            store.recordAttempt(.codex, at: failAttempt)
            store.saveError(.codex, "Not logged in")
        }
        let reopened = UsageStore(fileURL: url)
        XCTAssertEqual(reopened.lastError(.codex), "Not logged in")
        XCTAssertNotNil(reopened.snapshot(.codex), "stale data must be retained")
        XCTAssertEqual(reopened.lastSuccessAt(.codex)?.timeIntervalSinceReferenceDate ?? 0,
                       success.timeIntervalSinceReferenceDate, accuracy: 1e-6,
                       "freshness is the last success, not the failed attempt")

        // A subsequent success clears the error (invariant: error ⇔ last attempt failed).
        reopened.saveSnapshot(.codex, ProviderSnapshot(), at: failAttempt)
        XCTAssertNil(reopened.lastError(.codex))
    }

    /// The spend total defaults to $2500 when unset.
    func testDefaultSpendTotal() {
        let key = "aiut.customCostTotalCents"   // persistence key kept for back-compat
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Settings.customLimitCents, 250_000)
        Settings.customLimitCents = 300_00
        XCTAssertEqual(Settings.customLimitCents, 30000)
    }

    /// First run (key absent) enables all providers; an explicit choice — including
    /// turning everything off — persists instead of falling back to the default.
    func testEnabledProvidersFirstRunThenPersists() {
        let key = "aiut.enabledProviders"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Settings.enabledProviders, Set(ProviderID.allCases))

        Settings.enabledProviders = [.claude, .cursor]
        XCTAssertEqual(Settings.enabledProviders, [.claude, .cursor])

        // All-off is a real choice, not first run — it must stick.
        Settings.enabledProviders = []
        XCTAssertEqual(Settings.enabledProviders, [])
    }

    /// The spend display mode defaults to the pie ring and round-trips otherwise.
    func testSpendDisplayMode() {
        let key = "aiut.spendDisplayMode"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Settings.spendDisplayMode, .circle)
        Settings.spendDisplayMode = .text
        XCTAssertEqual(Settings.spendDisplayMode, .text)
        Settings.spendDisplayMode = .off
        XCTAssertEqual(Settings.spendDisplayMode, .off)
    }
}
