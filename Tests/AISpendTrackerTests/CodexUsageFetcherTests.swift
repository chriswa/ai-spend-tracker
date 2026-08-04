import XCTest
@testable import AISpendTracker

final class CodexUsageFetcherTests: XCTestCase {
    /// Free plan: a single ~30-day primary window, no secondary, no overage.
    func testDecodeFreePlan() throws {
        let json = """
        {
          "plan_type": "free",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 1, "limit_window_seconds": 2592000, "reset_at": 1786918827 },
            "secondary_window": null
          },
          "credits": { "has_credits": false, "unlimited": false, "balance": null },
          "spend_control": { "reached": false, "individual_limit": null }
        }
        """
        let snap = try CodexUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows.count, 1)
        let w = snap.windows[0]
        XCTAssertEqual(w.caption, "Monthly")                                   // 2_592_000s → Monthly
        XCTAssertEqual(w.utilization, 1)
        XCTAssertEqual(w.resetsAt, Date(timeIntervalSince1970: 1786918827))
        if case .rollingWindow(let len) = w.timeBasis { XCTAssertEqual(len, 2592000) } else { XCTFail("basis") }
        XCTAssertNil(snap.spend)                                               // no individual_limit
    }

    /// Paid plan: a 5-hour primary + weekly secondary, plus a monthly workspace credit
    /// pool. `individual_limit` is denominated in credits, valued at the estimated
    /// 4¢/credit rate — here delivered as numeric strings.
    func testDecodePaidPlanWithOverage() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 40, "limit_window_seconds": 18000, "reset_at": 1786900000 },
            "secondary_window": { "used_percent": 62, "limit_window_seconds": 604800, "reset_at": 1787400000 }
          },
          "spend_control": { "reached": false,
            "individual_limit": { "limit": "20000", "used": "1120", "remaining": "18880" } }
        }
        """
        let snap = try CodexUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows.map(\.caption), ["5-Hour", "Weekly"])
        XCTAssertEqual(snap.windows[0].utilization, 40)
        XCTAssertEqual(snap.windows[1].utilization, 62)
        XCTAssertEqual(snap.spend?.usedCents, 4480)                            // 1120 credits × 4¢
        XCTAssertEqual(snap.spend?.apiLimitCents, 80000)                       // 20000 credits × 4¢
        XCTAssertEqual(snap.spend?.label, "Codex overage")
    }

    /// The credit-pool figures may arrive as JSON numbers rather than strings; both
    /// forms decode to the same estimated dollar value.
    func testDecodeCreditPoolAsNumbers() throws {
        let json = """
        {
          "plan_type": "team",
          "rate_limit": { "primary_window": { "used_percent": 10, "limit_window_seconds": 604800, "reset_at": 1 }, "secondary_window": null },
          "spend_control": { "individual_limit": { "limit": 20000, "used": 1120.5, "remaining": 18879.5 } }
        }
        """
        let snap = try CodexUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.spend?.usedCents, 4482)                            // 1120.5 credits × 4¢
        XCTAssertEqual(snap.spend?.apiLimitCents, 80000)                       // 20000 credits × 4¢
    }

    /// A window without a length is skipped rather than producing a bogus pie.
    func testWindowWithoutLengthSkipped() throws {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 5, "reset_at": 100 }, "secondary_window": null } }
        """
        XCTAssertEqual(try CodexUsageFetcher.decode(Data(json.utf8)).windows.count, 0)
    }

    /// A subsidized "team" plan: a single weekly window (604800s), no secondary, no
    /// spend yet. Renders as one "Weekly" pie.
    func testDecodeTeamPlanSingleWeeklyWindow() throws {
        let json = """
        {
          "plan_type": "team",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 73, "limit_window_seconds": 604800, "reset_after_seconds": 563175, "reset_at": 1784899363 },
            "secondary_window": null
          },
          "credits": { "has_credits": true, "unlimited": false, "balance": null },
          "spend_control": { "reached": false, "individual_limit": null }
        }
        """
        let snap = try CodexUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.windows[0].caption, "Weekly")                       // 604800s → Weekly
        XCTAssertEqual(snap.windows[0].utilization, 73)
        XCTAssertEqual(snap.windows[0].resetsAt, Date(timeIntervalSince1970: 1784899363))
        if case .rollingWindow(let len) = snap.windows[0].timeBasis { XCTAssertEqual(len, 604800) }
        else { XCTFail("expected rolling window") }
        XCTAssertNil(snap.spend)
    }

    /// A usage-based business plan returns `rate_limit: null` (no windows) and no
    /// spend_control limit — it must decode without throwing, yielding an empty
    /// snapshot rather than crashing or inventing a window.
    func testDecodeUsageBasedBusinessPlanIsEmpty() throws {
        let json = """
        {
          "plan_type": "self_serve_business_usage_based",
          "rate_limit": null,
          "credits": { "has_credits": true, "unlimited": false, "balance": null },
          "spend_control": { "reached": false, "individual_limit": null }
        }
        """
        let snap = try CodexUsageFetcher.decode(Data(json.utf8))
        XCTAssertTrue(snap.windows.isEmpty)
        XCTAssertNil(snap.spend)
    }

    func testClassify() {
        let f = CodexUsageFetcher()
        XCTAssertEqual(f.classify(CodexUsageFetcher.NoAuthError()),
                       "Not logged in to Codex (~/.codex/auth.json missing)")
        // A 401 only reaches the user after a refresh already succeeded, so it reads as
        // an authorization problem rather than a stale token.
        XCTAssertEqual(f.classify(CodexUsageFetcher.UsageAPIError(status: 401, body: "")),
                       "Codex rejected our sign-in — run `codex login` again")
        XCTAssertEqual(f.classify(CodexUsageFetcher.UsageAPIError(status: 500, body: "")),
                       "Codex usage API returned 500")
        XCTAssertEqual(f.classify(CodexUsageFetcher.TokenRefreshError(
                            detail: "no codex CLI found to refresh it", expiredResponse: "HTTP 401")),
                       "Codex token expired — no codex CLI found to refresh it")
    }

    /// A failed refresh keeps the 401 body reachable for "copy last response", so the
    /// user can still see what the API actually said.
    func testTokenRefreshErrorCarriesTheExpiredResponse() {
        let e = CodexUsageFetcher.TokenRefreshError(detail: "boom", expiredResponse: "HTTP 401\n{}")
        XCTAssertTrue(e.rawResponse.contains("boom"))
        XCTAssertTrue(e.rawResponse.contains("HTTP 401"))
    }

    // MARK: - 401 → refresh → retry

    /// A missing/empty auth file short-circuits before any network call, so these tests
    /// exercise the refresh wiring without touching the real endpoint.
    private func tempAuth(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static let validAuth = #"{"tokens":{"access_token":"t","account_id":"acct"}}"#

    /// Canned HTTP replies, consumed in order, so a test can script "401 then 200".
    private static func transport(_ statuses: [Int], body: String = "{}")
        -> (CodexUsageFetcher.Transport, Counter) {
        let remaining = Queue(statuses)
        let requests = Counter()
        let transport: CodexUsageFetcher.Transport = { req in
            await requests.increment()
            let status = await remaining.next() ?? 200
            let response = HTTPURLResponse(url: req.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        return (transport, requests)
    }

    /// The headline behaviour: a 401 hands the refresh to the CLI and retries exactly
    /// once, so the fetch succeeds without the user touching anything.
    func testExpiredTokenRefreshesThenRetriesOnce() async throws {
        let refreshes = Counter()
        let (transport, requests) = Self.transport([401, 200])
        let f = CodexUsageFetcher(authPath: try tempAuth(Self.validAuth),
                                  refreshAuth: { await refreshes.increment() },
                                  transport: transport)

        let result = try await f.fetch()

        let (refreshCount, requestCount) = (await refreshes.count, await requests.count)
        XCTAssertTrue(result.snapshot.windows.isEmpty)      // "{}" decodes to an empty snapshot
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(requestCount, 2)                     // the 401 plus one retry
    }

    /// A 401 that survives the refresh is reported as an authorization problem, and we
    /// stop after one retry rather than looping.
    func testSecondUnauthorizedIsNotRetriedAgain() async throws {
        let refreshes = Counter()
        let (transport, requests) = Self.transport([401, 401])
        let f = CodexUsageFetcher(authPath: try tempAuth(Self.validAuth),
                                  refreshAuth: { await refreshes.increment() },
                                  transport: transport)
        do {
            _ = try await f.fetch()
            XCTFail("expected the second 401 to surface")
        } catch let e as CodexUsageFetcher.UsageAPIError {
            XCTAssertEqual(e.status, 401)
            XCTAssertEqual(f.classify(e), "Codex rejected our sign-in — run `codex login` again")
        }
        let (refreshCount, requestCount) = (await refreshes.count, await requests.count)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(requestCount, 2)
    }

    /// When the CLI can't be found, the 401 surfaces as `TokenRefreshError` explaining
    /// why — and we don't retry against a token we know is stale.
    func testRefreshFailureSurfacesWhyAndSkipsTheRetry() async throws {
        let (transport, requests) = Self.transport([401, 200])
        let f = CodexUsageFetcher(authPath: try tempAuth(Self.validAuth),
                                  refreshAuth: { throw CodexCLIAuth.CLINotFound() },
                                  transport: transport)
        do {
            _ = try await f.fetch()
            XCTFail("expected TokenRefreshError")
        } catch let e as CodexUsageFetcher.TokenRefreshError {
            XCTAssertEqual(f.classify(e), "Codex token expired — no codex CLI found to refresh it")
        }
        let requestCount = await requests.count
        XCTAssertEqual(requestCount, 1)
    }

    /// Non-401 failures never provoke a refresh — rotating the token wouldn't fix a 500.
    func testServerErrorDoesNotTriggerRefresh() async throws {
        let refreshes = Counter()
        let (transport, requests) = Self.transport([500])
        let f = CodexUsageFetcher(authPath: try tempAuth(Self.validAuth),
                                  refreshAuth: { await refreshes.increment() },
                                  transport: transport)
        do {
            _ = try await f.fetch()
            XCTFail("expected UsageAPIError")
        } catch let e as CodexUsageFetcher.UsageAPIError {
            XCTAssertEqual(e.status, 500)
        }
        let (refreshCount, requestCount) = (await refreshes.count, await requests.count)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(requestCount, 1)
    }

    /// Two expiries inside the cooldown perform one token exchange, not two: the second
    /// reports that a fresh refresh didn't help rather than rotating the token again.
    func testRepeatedExpiryRefreshesOnlyOncePerCooldown() async throws {
        let refreshes = Counter()
        let (transport, _) = Self.transport([401, 401, 401, 401])
        let f = CodexUsageFetcher(authPath: try tempAuth(Self.validAuth), refreshCooldown: 600,
                                  refreshAuth: { await refreshes.increment() },
                                  transport: transport)

        _ = try? await f.fetch()
        do {
            _ = try await f.fetch()
            XCTFail("expected the gate to block the second refresh")
        } catch let e as CodexUsageFetcher.TokenRefreshError {
            XCTAssertEqual(f.classify(e),
                           "Codex token expired — refreshed moments ago and still unauthorized")
        }
        let refreshCount = await refreshes.count
        XCTAssertEqual(refreshCount, 1)
    }

    /// No token on disk fails as `NoAuthError` and must *not* provoke a refresh — the
    /// CLI can't fix a logged-out account, and refreshing rotates a token needlessly.
    func testMissingTokenDoesNotTriggerRefresh() async throws {
        let calls = Counter()
        let f = CodexUsageFetcher(authPath: try tempAuth("{}"),
                                  refreshAuth: { await calls.increment() },
                                  transport: { _ in XCTFail("should not reach the network"); throw NoBody() })
        do {
            _ = try await f.fetch()
            XCTFail("expected NoAuthError")
        } catch is CodexUsageFetcher.NoAuthError {
            // expected
        }
        let refreshCount = await calls.count
        XCTAssertEqual(refreshCount, 0)
    }

    private struct NoBody: Error {}

    /// The gate blocks a second refresh inside the cooldown, so a burst of failing
    /// fetches performs one token exchange rather than one per attempt.
    func testRefreshGateBlocksRepeatAttemptsWithinCooldown() async {
        let gate = CodexUsageFetcher.RefreshGate(cooldown: 60)
        let start = Date()
        let first = await gate.claim(now: start)
        let tooSoon = await gate.claim(now: start.addingTimeInterval(30))
        let afterCooldown = await gate.claim(now: start.addingTimeInterval(61))
        XCTAssertTrue(first)
        XCTAssertFalse(tooSoon)
        XCTAssertTrue(afterCooldown)
    }

    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    /// Scripted responses, popped in order.
    private actor Queue {
        private var items: [Int]
        init(_ items: [Int]) { self.items = items }
        func next() -> Int? { items.isEmpty ? nil : items.removeFirst() }
    }
}
