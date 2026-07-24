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
        XCTAssertEqual(f.classify(CodexUsageFetcher.UsageAPIError(status: 401, body: "")),
                       "Codex token expired — open Codex to refresh it")
        XCTAssertEqual(f.classify(CodexUsageFetcher.UsageAPIError(status: 500, body: "")),
                       "Codex usage API returned 500")
    }
}
