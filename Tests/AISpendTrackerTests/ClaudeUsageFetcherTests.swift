import XCTest
@testable import AISpendTracker

final class ClaudeUsageFetcherTests: XCTestCase {
    private func window(_ snap: ProviderSnapshot, _ caption: String) -> UsageWindow? {
        snap.windows.first { $0.caption == caption }
    }

    /// A fresh/idle 5-hour window comes back with null utilization + resets_at. It
    /// must render as 0% usage / 0% time (window not started), not "no data" and not
    /// a decode failure.
    func testNullFiveHourWindowReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": null, "resets_at": null },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" },
          "extra_usage": { "is_enabled": true, "used_credits": 12345, "monthly_limit": 50000, "utilization": 24.69 }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let five = try XCTUnwrap(window(snap, "5-Hour"))
        XCTAssertEqual(five.utilization, 0)                                     // 0% usage
        XCTAssertNil(five.resetsAt)                                             // no reset yet …
        XCTAssertEqual(UsageMath.timeFraction(five.timeBasis, resetsAt: five.resetsAt, now: Date()), 0) // → 0% time
        XCTAssertEqual(window(snap, "7-Day")?.utilization, 63)                  // others still parse
    }

    /// Same for a null 7-day window.
    func testNullSevenDayWindowReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": null, "resets_at": null }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let seven = try XCTUnwrap(window(snap, "7-Day"))
        XCTAssertEqual(seven.utilization, 0)
        XCTAssertNil(seven.resetsAt)
        XCTAssertEqual(UsageMath.timeFraction(seven.timeBasis, resetsAt: seven.resetsAt, now: Date()), 0)
    }

    /// Null spend fields read as $0.
    func testNullSpendReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" },
          "extra_usage": { "is_enabled": true, "used_credits": null, "monthly_limit": 50000, "utilization": null }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.usedCents, 0)
        XCTAssertEqual(spend.apiLimitCents, 50000)
        XCTAssertEqual(UsageMath.spendFraction(usedCents: spend.usedCents, limitCents: 50000), 0)
    }

    /// Spend maps used_credits → cents and monthly_limit → apiLimitCents.
    func testSpendDecodes() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" },
          "extra_usage": { "is_enabled": true, "used_credits": 12345, "monthly_limit": 50000, "utilization": 24.69 }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.spend?.usedCents, 12345)
        XCTAssertEqual(snap.spend?.apiLimitCents, 50000)
        XCTAssertEqual(snap.spend?.label, "Claude extra usage")
    }

    /// Missing extra_usage → no spend contribution.
    func testMissingSpendIsNil() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" }
        }
        """
        XCTAssertNil(try ClaudeUsageFetcher.decode(Data(json.utf8)).spend)
    }

    func testDecodeFractionalAndPlainTimestamps() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00.123Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertNotNil(window(snap, "5-Hour")?.resetsAt)
        XCTAssertNotNil(window(snap, "7-Day")?.resetsAt)
    }

    /// The `limits` array drives the window list: a session + weekly pair plus a
    /// per-model scoped weekly window, in array order, captioned "5-Hour", "7-Day",
    /// "Fable 7-Day". `percent`/`resets_at` map to utilization/reset.
    func testLimitsDriveWindowsIncludingScoped() throws {
        let json = """
        {
          "five_hour": { "utilization": 37, "resets_at": "2026-07-20T20:50:00Z" },
          "seven_day": { "utilization": 55, "resets_at": "2026-07-22T21:00:00Z" },
          "limits": [
            { "kind": "session", "group": "session", "percent": 37, "resets_at": "2026-07-20T20:50:00.4Z", "scope": null },
            { "kind": "weekly_all", "group": "weekly", "percent": 55, "resets_at": "2026-07-22T21:00:00.4Z", "scope": null },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 12, "resets_at": "2026-07-22T21:00:00.4Z",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows.map(\.caption), ["5-Hour", "7-Day", "Fable 7-Day"])
        XCTAssertEqual(window(snap, "Fable 7-Day")?.utilization, 12)
        XCTAssertNotNil(window(snap, "Fable 7-Day")?.resetsAt)
        // Only the per-model scoped window is flagged scoped; the account-wide pair isn't.
        XCTAssertEqual(window(snap, "Fable 7-Day")?.isScoped, true)
        XCTAssertEqual(window(snap, "5-Hour")?.isScoped, false)
        XCTAssertEqual(window(snap, "7-Day")?.isScoped, false)
    }

    /// When the `limits` array omits a window (here: no scoped/Fable entry), no pie
    /// is produced for it — existence is driven entirely by the JSON.
    func testMissingScopedLimitOmitsItsPie() throws {
        let json = """
        {
          "limits": [
            { "kind": "session", "group": "session", "percent": 20, "resets_at": null, "scope": null },
            { "kind": "weekly_all", "group": "weekly", "percent": 40, "resets_at": null, "scope": null }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows.map(\.caption), ["5-Hour", "7-Day"])
    }

    /// An unrecognized window group (one we can't size) is skipped rather than guessed.
    func testUnknownLimitGroupIsSkipped() throws {
        let json = """
        {
          "limits": [
            { "kind": "session", "group": "session", "percent": 20, "resets_at": null, "scope": null },
            { "kind": "monthly_all", "group": "monthly", "percent": 40, "resets_at": null, "scope": null }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows.map(\.caption), ["5-Hour"])
    }

    /// An idle scoped window (null percent + reset) reads as 0% usage, not a failure.
    func testIdleScopedLimitReadsAsZero() throws {
        let json = """
        {
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": null, "resets_at": null,
              "scope": { "model": { "display_name": "Fable" } } }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let fable = try XCTUnwrap(window(snap, "Fable 7-Day"))
        XCTAssertEqual(fable.utilization, 0)
        XCTAssertNil(fable.resetsAt)
    }

    /// With no `limits` array (older responses), the legacy top-level buckets still
    /// render the core 5-hour + 7-day pair.
    func testLegacyFallbackWithoutLimits() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows.map(\.caption), ["5-Hour", "7-Day"])
        XCTAssertEqual(window(snap, "7-Day")?.utilization, 63)
    }

    /// A 401 body should surface the API's own error message, not a raw blob.
    func testAPIErrorUserMessageExtractsMessage() {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"Invalid authentication credentials"},"request_id":"req_x"}"#
        let e = ClaudeUsageFetcher.UsageAPIError(status: 401, body: body)
        XCTAssertEqual(e.userMessage, "Usage API 401: Invalid authentication credentials")
    }

    func testAPIErrorUserMessageFallsBackToTrimmedBody() {
        let e = ClaudeUsageFetcher.UsageAPIError(status: 503, body: "  service unavailable\n")
        XCTAssertEqual(e.userMessage, "Usage API 503: service unavailable")
    }

    /// Error taxonomy: each error maps to its own user-facing message.
    func testClassify() {
        let f = ClaudeUsageFetcher()
        XCTAssertEqual(f.classify(ClaudeUsageFetcher.NoOAuthCredentialsError()),
                       "No Claude subscription credentials in Keychain (API-key account?)")
        XCTAssertTrue(f.classify(ClaudeUsageFetcher.KeychainError(detail: "locked")).contains("locked"))
        XCTAssertEqual(f.classify(ClaudeUsageFetcher.UsageAPIError(status: 500, body: "")),
                       "Usage API returned 500")
    }

    /// A decode failure wrapped in `ResponseParseError` still classifies as a parse
    /// error (the wrapper defers to the underlying), and preserves the raw body so the
    /// user can copy what the server actually sent.
    func testParseErrorUnwrapsAndKeepsRaw() {
        let f = ClaudeUsageFetcher()
        let underlying = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        let wrapped = ResponseParseError(rawResponse: "{not json", underlying: underlying)
        XCTAssertEqual(f.classify(wrapped), f.classify(underlying))
        XCTAssertEqual((wrapped as RawResponseCarrying).rawResponse, "{not json")
    }

    /// An HTTP-error body is surfaced verbatim (with its status) for "copy last response".
    func testAPIErrorCarriesRawResponse() {
        let e = ClaudeUsageFetcher.UsageAPIError(status: 429, body: "slow down")
        XCTAssertEqual((e as RawResponseCarrying).rawResponse, "HTTP 429\nslow down")
    }
}
