import XCTest
@testable import AISpendTracker

/// A fetch failure must never stop polling — it surfaces the error and retries on
/// the next cooldown. These tests pin that behavior: no single error can brick a
/// provider (the "credentials vanish mid-rotation" bug), and "Refresh Now" always
/// attempts a fetch.
@MainActor
final class UsagePollerTests: XCTestCase {
    /// A provider whose `fetch()` always fails — standing in for a missing/absent
    /// credential, the error that used to be treated as a permanent stop.
    private struct AlwaysFailingProvider: UsageProvider {
        struct Failure: Error {}
        let id: ProviderID = .claude
        let displayName = "Fake"
        let suggestedInterval: TimeInterval = 300
        func fetch() async throws -> FetchResult { throw Failure() }
        func classify(_ error: Error) -> String { "no credentials" }
    }

    /// The regression: a failing fetch reports the error but keeps the poller alive,
    /// so it will retry on the next cooldown rather than bricking itself.
    func testFailureDoesNotStopPolling() async {
        let poller = UsagePoller(provider: AlwaysFailingProvider(), lastAttemptAt: nil)
        let failed = expectation(description: "error reported")
        poller.onError = { _, _ in failed.fulfill() }
        poller.fetchNow()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(poller.isStopped)
        poller.stop()   // cancel the retry timer scheduled by the failure path
    }

    /// "Refresh Now" attempts a fetch even after the poller was explicitly stopped
    /// (e.g. re-enabling a provider), so the button is never a dead no-op.
    func testRefreshAttemptsAfterStop() async {
        let poller = UsagePoller(provider: AlwaysFailingProvider(), lastAttemptAt: nil)
        var errorCount = 0
        let first = expectation(description: "first attempt")
        let second = expectation(description: "second attempt")
        poller.onError = { _, _ in
            errorCount += 1
            if errorCount == 1 { first.fulfill() }
            if errorCount == 2 { second.fulfill() }
        }
        poller.fetchNow()
        await fulfillment(of: [first], timeout: 2)

        poller.stop()
        XCTAssertTrue(poller.isStopped)

        poller.fetchNow()                        // explicit retry must run despite stop
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(errorCount, 2)
        XCTAssertFalse(poller.isStopped)         // fetchNow cleared the stopped flag
        poller.stop()
    }
}
