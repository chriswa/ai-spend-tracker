import AppKit

/// Draws a time-positioned line sparkline: the horizontal axis is a fixed window
/// ending at `now`, and each point sits at its real time — so sparse data leaves
/// gaps (blank stretches) rather than being stretched across the width. The line
/// is broken wherever consecutive samples are more than `gapThreshold` apart
/// (missed samples), so we never draw across data we don't have. Vertical scale is
/// 0…max (quiet rests on the bottom line, bursts spike up). The line is drawn in
/// `color`; when `background` is given, a dark panel is filled behind it so the line
/// reads against the theme's dim tone instead of framing hairlines. Kept as a free
/// function so both the menu view and the debug preview share it.
enum Sparkline {
    static func draw(points: [(Date, Double)], window: TimeInterval, now: Date,
                     in rect: NSRect, color: NSColor, background: NSColor? = nil,
                     gapThreshold: TimeInterval,
                     leftInset: CGFloat = 21, rightInset: CGFloat = 16, vInset: CGFloat = 5) {
        let w = rect.width - leftInset - rightInset
        let h = rect.height - 2 * vInset
        guard w > 0, h > 0 else { return }
        let x0 = rect.minX + leftInset
        let yBottom = rect.minY + vInset

        // A dark panel behind the line, in the theme's dim tone.
        if let background {
            background.setFill()
            rect.fill()
        }

        guard points.count >= 2 else { return }
        let start = now.addingTimeInterval(-window)
        let maxV = max(points.map { $0.1 }.max() ?? 0, 0)
        func x(_ date: Date) -> CGFloat {
            x0 + w * CGFloat(min(1, max(0, date.timeIntervalSince(start) / window)))
        }
        func y(_ value: Double) -> CGFloat { maxV > 0 ? yBottom + h * CGFloat(value / maxV) : yBottom }

        let path = NSBezierPath()
        var penDown = false
        for i in 0..<points.count {
            let p = NSPoint(x: x(points[i].0), y: y(points[i].1))
            // Break the line across a gap wider than expected (missed samples).
            if i > 0, points[i].0.timeIntervalSince(points[i - 1].0) > gapThreshold { penDown = false }
            if penDown { path.line(to: p) } else { path.move(to: p); penDown = true }
        }
        path.lineWidth = 1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

/// A menu-item view hosting one sparkline of *usage rate* — per-minute deltas of
/// its metric — over a fixed 2-hour window ending now, so it spikes during bursts
/// and rests near zero when idle. Drawn in the adaptive label color (white in dark
/// mode, near-black in light mode). Assign the raw cumulative samples (with times);
/// the view derives the rate and positions everything on the time axis itself.
@MainActor
final class SparklineView: NSView {
    /// Raw cumulative samples (utilization % or spend cents) with timestamps,
    /// oldest first, already trimmed to the display window by the caller.
    var samples: [(Date, Double)] = [] { didSet { needsDisplay = true } }

    /// Break the line when samples are more than this far apart — a bit over the
    /// ~5-minute fetch cadence, so a single missed sample shows as a gap.
    private static let gapThreshold: TimeInterval = 8 * 60

    override func draw(_ dirtyRect: NSRect) {
        Sparkline.draw(points: UsageMath.usageRatePoints(samples, unit: .percent),
                       window: UsageHistory.sparklineWindow, now: Date(),
                       in: bounds, color: .labelColor, gapThreshold: Self.gapThreshold)
    }
}
