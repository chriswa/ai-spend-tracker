import XCTest
@testable import AISpendTracker

/// Locks in how an errored provider renders in each context: the tray collapses it to a
/// single warning glyph, while the dropdown header keeps its last good windows as dimmed
/// "stale" pies — the one intentional divergence between the two circle lists.
final class PieChartTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func erroredCodex(withSnapshot: Bool) -> ProviderView {
        let snap = withSnapshot
            ? ProviderSnapshot(windows: [
                UsageWindow(caption: "5-Hour", utilization: 42, resetsAt: now.addingTimeInterval(3600),
                            timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
                UsageWindow(caption: "Weekly", utilization: 71, resetsAt: now.addingTimeInterval(86_400),
                            timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
              ])
            : nil
        return ProviderView(id: .codex, displayName: "Codex", snapshot: snap,
                            lastUpdated: now.addingTimeInterval(-3600), error: "Not logged in")
    }

    private func vm(_ providers: [ProviderView]) -> TrayViewModel {
        TrayViewModel(providers: providers, customLimitCents: 0)
    }

    func testTrayCollapsesErroredProviderToGlyph() {
        let circles = PieChart.circles(from: vm([erroredCodex(withSnapshot: true)]), now: now)
        XCTAssertEqual(circles.count, 1)
        XCTAssertEqual(circles[0].kind, .error)
        XCTAssertFalse(circles[0].isStale)
    }

    func testHeaderShowsStalePiesForErroredProviderWithSnapshot() {
        let circles = PieChart.circles(from: vm([erroredCodex(withSnapshot: true)]),
                                       now: now, errorStyle: .staleData)
        XCTAssertEqual(circles.count, 2, "both retained windows should render")
        XCTAssertTrue(circles.allSatisfy { $0.isStale })
        XCTAssertEqual(circles.map(\.caption), ["5-Hour", "Weekly"])
        // Stale pies keep the reading; only their color is dimmed vs the live palette.
        for c in circles {
            guard case .pie = c.kind else { return XCTFail("expected a pie, got \(c.kind)") }
        }
        let live = PieChart.palette(for: .codex).usage
        XCTAssertLessThan(circles[0].usageColor.usingColorSpace(.sRGB)!.brightnessComponent,
                          live.usingColorSpace(.sRGB)!.brightnessComponent)
    }

    func testHeaderFallsBackToGlyphWhenNoSnapshotRetained() {
        let circles = PieChart.circles(from: vm([erroredCodex(withSnapshot: false)]),
                                       now: now, errorStyle: .staleData)
        XCTAssertEqual(circles.count, 1)
        XCTAssertEqual(circles[0].kind, .error)
    }
}
