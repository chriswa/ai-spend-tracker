import XCTest
@testable import AISpendTracker

final class CursorUsageFetcherTests: XCTestCase {
    /// A real enterprise payload → one monthly window (utilization is the already-%
    /// `totalPercentUsed`) + on-demand spend in cents.
    func testDecode() throws {
        let json = """
        {
          "billingCycleStart": "2026-07-04T14:51:16.000Z",
          "billingCycleEnd": "2026-08-04T14:51:16.000Z",
          "isUnlimited": false,
          "individualUsage": {
            "plan": { "used": 2000, "limit": 2000, "totalPercentUsed": 17.706666666666667 },
            "onDemand": { "used": 39397, "limit": 220000 }
          }
        }
        """
        let snap = try CursorUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows.count, 1)
        let w = snap.windows[0]
        XCTAssertEqual(w.caption, "Monthly")
        XCTAssertEqual(w.utilization, 17.706666, accuracy: 1e-4)               // already a percentage
        XCTAssertNotNil(w.resetsAt)
        if case .interval(let start, let end) = w.timeBasis {
            XCTAssertLessThan(start, end)
        } else { XCTFail("expected interval basis") }
        XCTAssertEqual(snap.spend?.usedCents, 39397)                           // on-demand cents → $393.97
        XCTAssertEqual(snap.spend?.apiLimitCents, 220000)
        XCTAssertEqual(snap.spend?.label, "Cursor on-demand")
    }

    /// Missing dates fall back to no time basis rather than failing.
    func testDecodeWithoutCycleDates() throws {
        let json = #"{ "individualUsage": { "plan": { "totalPercentUsed": 42.5 } } }"#
        let snap = try CursorUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.windows[0].utilization, 42.5, accuracy: 1e-9)
        XCTAssertEqual(snap.windows[0].timeBasis, .none)
    }

    /// The cookie's userId is the JWT `sub` after the "|".
    func testUserIdFromJWT() throws {
        let payload = #"{"sub":"google-oauth2|user_01ABCDEF"}"#
        let b64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "header.\(b64).signature"
        XCTAssertEqual(try CursorUsageFetcher.userId(fromJWT: jwt), "user_01ABCDEF")
    }

    func testUserIdRejectsNonJWT() {
        XCTAssertThrowsError(try CursorUsageFetcher.userId(fromJWT: "not-a-jwt"))
    }

    func testClassify() {
        let f = CursorUsageFetcher()
        XCTAssertEqual(f.classify(CursorUsageFetcher.NoCredentialsError()),
                       "Not signed in to Cursor (no Keychain token)")
        XCTAssertEqual(f.classify(CursorUsageFetcher.MalformedTokenError()),
                       "Cursor token wasn't a readable JWT")
        XCTAssertTrue(f.classify(CursorUsageFetcher.UnsupportedResponseError(body: "<html>")).contains("not supported"))
        XCTAssertEqual(f.classify(CursorUsageFetcher.UsageAPIError(status: 500, body: "")),
                       "Cursor usage API returned 500")
    }
}
