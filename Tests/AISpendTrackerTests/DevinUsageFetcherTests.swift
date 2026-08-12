import XCTest
@testable import AISpendTracker

final class DevinUsageFetcherTests: XCTestCase {
    /// A real `GetUserStatus` shape → a Daily and a Weekly window. The quota fields
    /// arrive mixed: percentages as JSON numbers, reset unix timestamps as strings.
    /// Utilization is `100 − remaining%`.
    func testDecodeQuotaWindows() throws {
        let json = """
        {
          "userStatus": {
            "email": "chris.waddell@spare.com",
            "planStatus": {
              "planInfo": { "planName": "Teams" },
              "dailyQuotaRemainingPercent": 87,
              "weeklyQuotaRemainingPercent": 93,
              "dailyQuotaResetAtUnix": "1786608000",
              "weeklyQuotaResetAtUnix": "1786867200"
            }
          }
        }
        """
        let status = try DevinUsageFetcher.decodeStatus(Data(json.utf8))
        XCTAssertEqual(status.email, "chris.waddell@spare.com")
        XCTAssertEqual(status.windows.count, 2)

        let daily = status.windows[0]
        XCTAssertEqual(daily.caption, "Daily")
        XCTAssertEqual(daily.utilization, 13, accuracy: 1e-9)                  // 100 − 87
        XCTAssertEqual(daily.resetsAt, Date(timeIntervalSince1970: 1786608000))
        XCTAssertEqual(daily.timeBasis, .rollingWindow(length: 24 * 60 * 60))

        let weekly = status.windows[1]
        XCTAssertEqual(weekly.caption, "Weekly")
        XCTAssertEqual(weekly.utilization, 7, accuracy: 1e-9)                  // 100 − 93
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1786867200))
        XCTAssertEqual(weekly.timeBasis, .rollingWindow(length: WindowLength.sevenDay))
    }

    /// Percentages can also arrive as strings; both fields are decoded leniently.
    func testDecodeAcceptsStringPercentages() throws {
        let json = """
        { "userStatus": { "planStatus": {
            "dailyQuotaRemainingPercent": "40.5", "dailyQuotaResetAtUnix": 1786608000
        } } }
        """
        let status = try DevinUsageFetcher.decodeStatus(Data(json.utf8))
        XCTAssertEqual(status.windows.count, 1)
        XCTAssertEqual(status.windows[0].utilization, 59.5, accuracy: 1e-9)
    }

    /// A plan with no quota fields contributes no rings rather than a misleading 0%.
    func testDecodeWithoutQuotaYieldsNoWindows() throws {
        let json = #"{ "userStatus": { "email": "x@y.com", "planStatus": { "planInfo": { "planName": "Teams" } } } }"#
        let status = try DevinUsageFetcher.decodeStatus(Data(json.utf8))
        XCTAssertTrue(status.windows.isEmpty)
        XCTAssertEqual(status.email, "x@y.com")
    }

    /// Only one of the two quotas present → only that window.
    func testDecodeWeeklyOnly() throws {
        let json = """
        { "userStatus": { "planStatus": {
            "weeklyQuotaRemainingPercent": 100, "weeklyQuotaResetAtUnix": "1786867200"
        } } }
        """
        let status = try DevinUsageFetcher.decodeStatus(Data(json.utf8))
        XCTAssertEqual(status.windows.count, 1)
        XCTAssertEqual(status.windows[0].caption, "Weekly")
        XCTAssertEqual(status.windows[0].utilization, 0, accuracy: 1e-9)
    }

    /// A garbage body is surfaced as a parse error carrying the raw text (for "copy
    /// last response"), not a silent empty snapshot.
    func testDecodeGarbageThrowsParseError() {
        XCTAssertThrowsError(try DevinUsageFetcher.decodeStatus(Data("not json".utf8))) { error in
            XCTAssertTrue(error is ResponseParseError)
        }
    }

    func testClassify() {
        let f = DevinUsageFetcher()
        XCTAssertEqual(f.classify(DevinAuth.NotSignedInError()),
                       "Not signed in to Devin (no Devin CLI or Devin Desktop login found)")
        XCTAssertEqual(f.classify(DevinUsageFetcher.APIError(endpoint: "GetUserStatus", status: 500, body: "")),
                       "Devin usage API returned 500")
        XCTAssertEqual(f.classify(DevinUsageFetcher.APIError(endpoint: "api/billing/subscription", status: 503, body: "")),
                       "Devin billing API returned 503")
    }
}
