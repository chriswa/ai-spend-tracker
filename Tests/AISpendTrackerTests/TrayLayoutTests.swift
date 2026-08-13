import XCTest
@testable import AISpendTracker

/// Locks in the tray row's horizontal layout in both styles: which circles open a new
/// group (so the bar row's wider provider-boundary gap lands in the right places), that
/// the composed image is exactly as wide as its glyphs and their gaps — no outer margin —
/// and that rings stay the default.
@MainActor
final class TrayLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func provider(_ id: ProviderID, _ captions: [String]) -> ProviderView {
        ProviderView(id: id, displayName: "\(id)",
                     snapshot: ProviderSnapshot(windows: captions.map {
                         UsageWindow(caption: $0, utilization: 50, resetsAt: now.addingTimeInterval(3600),
                                     timeBasis: .rollingWindow(length: WindowLength.fiveHour))
                     }),
                     lastUpdated: now)
    }

    /// Claude (3 windows), Codex (1), Cursor (1), Devin (2), then the spend circle.
    private func fullHouse() -> [PieChart.Circle] {
        let vm = TrayViewModel(providers: [
            provider(.claude, ["5-Hour", "7-Day", "Fable 7-Day"]),
            provider(.codex, ["Weekly"]),
            provider(.cursor, ["Monthly"]),
            provider(.devin, ["Daily", "Weekly"]),
        ], customLimitCents: 100_000)
        return PieChart.circles(from: vm, now: now)
    }

    func testOnlyFirstWindowOfEachProviderStartsAGroup() {
        let circles = fullHouse()
        XCTAssertEqual(circles.count, 7, "no provider reports spend, so there's no spend circle")
        XCTAssertEqual(circles.map(\.startsGroup),
                       [true, false, false,   // Claude's three windows
                        true,                 // Codex
                        true,                 // Cursor
                        true, false])         // Devin's two
    }

    func testSpendCircleStartsItsOwnGroup() {
        var claude = provider(.claude, ["5-Hour"])
        claude.snapshot?.spend = SpendInfo(usedCents: 5000, apiLimitCents: 20000, label: "Claude extra usage")
        let circles = PieChart.circles(from: TrayViewModel(providers: [claude], customLimitCents: 100_000), now: now)
        XCTAssertEqual(circles.count, 2)
        XCTAssertTrue(circles[1].startsGroup)
    }

    func testErroredProviderStartsAGroup() {
        let errored = ProviderView(id: .codex, displayName: "Codex", lastUpdated: now, error: "Not logged in")
        let circles = PieChart.circles(from: TrayViewModel(providers: [provider(.claude, ["5-Hour"]), errored],
                                                           customLimitCents: 0), now: now)
        XCTAssertEqual(circles.map(\.kind), [.pie(time: circles[0].pieTime, usage: 0.5), .error])
        XCTAssertTrue(circles[1].startsGroup)
    }

    /// The image ends flush with the outermost bars, so the only space around the row is
    /// the menu bar's own status-item padding.
    func testImageWidthIsBarsPlusGapsWithNoOuterMargin() {
        let circles = fullHouse()
        let bars = CGFloat(circles.count) * TrayBars.barWidth
        // Claude contributes 2 within-provider gaps, Devin 1; the other 3 boundaries are
        // provider changes.
        let expected = bars + 3 * TrayBars.windowGap + 3 * TrayBars.groupGap
        XCTAssertEqual(TrayBars.size(circles: circles).width, expected, accuracy: 0.001)
        XCTAssertEqual(TrayBars.image(circles: circles).size.width, expected, accuracy: 0.001)
    }

    /// The only signal that a window is maxed out is its frame going solid white, so the
    /// threshold has to sit exactly at 100% — not a hair under.
    func testFrameBrightensOnlyAtFullUsage() {
        XCTAssertEqual(TrayBars.frameColor(usage: 0.999), TrayBars.hairline)
        XCTAssertEqual(TrayBars.frameColor(usage: 1), TrayBars.hairlineMaxed)
        XCTAssertEqual(TrayBars.frameColor(usage: 1.4), TrayBars.hairlineMaxed)
    }

    func testErrorSlotIsSquareSoTheWarningGlyphStaysLegible() {
        let errored = ProviderView(id: .codex, displayName: "Codex", lastUpdated: now, error: "Not logged in")
        let circles = PieChart.circles(from: TrayViewModel(providers: [errored], customLimitCents: 0), now: now)
        XCTAssertEqual(TrayBars.slotWidth(circles[0]), TrayBars.height)
    }

    /// A tray with nothing enabled still draws one placeholder glyph in either style, so
    /// the status item stays clickable.
    func testEmptyTrayKeepsOneClickableSlot() {
        XCTAssertEqual(TrayBars.image(circles: []).size.width, TrayBars.barWidth, accuracy: 0.001)
        XCTAssertEqual(TrayRings.image(circles: []).size.width, TrayRings.diameter, accuracy: 0.001)
    }

    func testRingsAreTheDefaultStyle() {
        XCTAssertEqual(TrayViewModel(providers: [], customLimitCents: 0).trayStyle, .rings)
    }

    /// Both styles render the same circles; only the shape and footprint differ. Bars
    /// exist for the width, so a regression that lost that advantage should fail here.
    func testBothStylesRenderAndBarsAreNarrower() {
        let circles = fullHouse()
        let rings = TrayStyle.rings.image(circles: circles, isDark: true).size
        let bars = TrayStyle.bars.image(circles: circles, isDark: true).size
        XCTAssertEqual(rings.width, TrayRings.size(circles: circles.count).width, accuracy: 0.001)
        XCTAssertEqual(bars.width, TrayBars.size(circles: circles).width, accuracy: 0.001)
        XCTAssertLessThan(bars.width, rings.width * 0.7)
    }
}

private extension PieChart.Circle {
    /// The time fraction of a `.pie`, for tests that only care about the usage half.
    var pieTime: Double {
        if case .pie(let time, _) = kind { return time }
        return .nan
    }
}
