import AppKit

/// Renders the status-item image as a row of rings — the same pies the dropdown header
/// draws, shrunk to menu-bar size. The peer of `TrayBars`; which one the tray uses is
/// `TrayStyle`'s call. Rings show the two readings as a dial (a dim time wedge under a
/// bright usage arc), which is the more literal picture but costs about twice the width.
///
/// The per-circle drawing lives in `PieChart` so the tray and the header stay in
/// lockstep; this type only owns the tray's geometry and layout.
enum TrayRings {
    // Geometry (points). The circle diameter tracks the live menu-bar height so the
    // tray icon fills it like other status items, rather than sitting small in the bar.
    // A ~4pt margin keeps the outline off the bar edges; the floor guards odd values.
    static var diameter: CGFloat { max(15, NSStatusBar.system.thickness - 4) }
    static let gap: CGFloat = 5

    /// Rings are uniform, so width is just count × diameter plus the gaps between them —
    /// flush at both ends, no outer margin.
    static func size(circles: Int) -> NSSize {
        let n = max(1, circles)   // always at least one slot so the tray item is clickable
        return NSSize(width: CGFloat(n) * diameter + CGFloat(n - 1) * gap, height: diameter + 2)
    }

    /// Compose a tray image straight from a view model. `outline` is the hairline color
    /// for the current menu-bar appearance (white on dark, black on light) — unlike a
    /// bar's frame, a ring's hairline sits on its outer edge against the bar itself.
    static func trayImage(from vm: TrayViewModel, now: Date = Date(),
                          outline: NSColor = PieChart.outline) -> NSImage {
        image(circles: PieChart.circles(from: vm, now: now), outline: outline)
    }

    static func image(circles: [PieChart.Circle], outline: NSColor = PieChart.outline) -> NSImage {
        // With nothing enabled/fetched, draw a single empty ring so the item stays visible.
        let drawn = circles.isEmpty
            ? [PieChart.Circle(kind: .pie(time: 0, usage: 0), caption: "",
                               usageColor: PieChart.spendPalette.usage,
                               timeColor: PieChart.spendPalette.time)]
            : circles
        let size = size(circles: drawn.count)
        let image = NSImage(size: size, flipped: false) { _ in
            let y = (size.height - diameter) / 2
            for (i, c) in drawn.enumerated() {
                let rect = NSRect(x: CGFloat(i) * (diameter + gap), y: y, width: diameter, height: diameter)
                // The tray drops the black rim so the tiny pies keep their full size.
                PieChart.draw(c, in: rect, bordered: false, outline: outline)
            }
            return true
        }
        image.isTemplate = false   // real colors, not a monochrome template
        return image
    }
}
