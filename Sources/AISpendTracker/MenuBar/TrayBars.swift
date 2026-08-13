import AppKit

/// Renders the status-item image as a row of narrow vertical bars — one per
/// `PieChart.Circle` — instead of the circles used in the dropdown header. Eight-plus
/// pies eat far too much horizontal room in the menu bar; a bar carries the same two
/// readings in roughly a third of the width.
///
/// Each bar is the same two layers as a pie, unrolled from a dial into a column that
/// fills bottom-up:
///   1. a black backing rect (the empty remainder), full slot width,
///   2. the "time" layer as a dim column [0 … time] across the full slot width,
///   3. the "usage" layer as a bright stripe [0 … usage] in the right-hand lane,
///      over the time column,
///   4. a hairline framing the whole bar, brightening to solid white at ≥100% usage.
/// Bars are separated by whitespace, tight within one provider's windows and wider at
/// each provider boundary (`Circle.startsGroup`), so the row reads as a few provider
/// clusters rather than one undifferentiated picket fence. Colors come from the same
/// `PieChart.Circle`, so tray and header can never disagree about a reading — only
/// about its shape.
enum TrayBars {
    // Geometry (points). Bars run the full usable menu-bar height, matching what the
    // circles occupied vertically; only the width changes.
    static var height: CGFloat { max(15, NSStatusBar.system.thickness - 4) }

    /// Width of the bright usage stripe — the thickness of the old pie's usage ring
    /// lane, which is the width that reading was already legible at.
    static var usageWidth: CGFloat {
        max(3, (height / 2 * (1 - PieChart.ringInnerRatio)).rounded())
    }
    /// Full width of a bar: the usage stripe on the right, a dim time-only lane twice
    /// that wide to its left.
    static var barWidth: CGFloat { usageWidth * 3 }
    /// Space between two windows of the same provider.
    static let windowGap: CGFloat = 2
    /// Space at a provider boundary — wide enough to group the bars on either side,
    /// still far tighter than the circles it replaced.
    static let groupGap: CGFloat = 5
    /// Hairline framing each bar, keeping neighbours from reading as one slab and
    /// giving the black backing a visible edge on a pale menu bar. Drawn inside the
    /// slot over the black backing, so it contrasts in light and dark alike.
    static let hairlineWidth: CGFloat = 0.5
    static let hairline = NSColor(white: 1, alpha: 0.25)
    /// The frame for a window at 100%: the same hairline at full opacity, so a maxed
    /// reading flags itself by brightening its outline rather than by any extra mark
    /// inside the bar.
    static let hairlineMaxed = NSColor(white: 1, alpha: 1)

    /// Frame color for a usage fraction — bright only at 100%.
    static func frameColor(usage: Double) -> NSColor { usage >= 1 ? hairlineMaxed : hairline }

    /// Slot width for one circle. A failed provider's warning triangle needs a square
    /// slot to stay recognizable — squeezed into a bar's width it reads as a smudge.
    static func slotWidth(_ circle: PieChart.Circle) -> CGFloat {
        switch circle.kind {
        case .pie: return barWidth
        case .error: return height
        }
    }

    /// Space to the left of slot `i`: none for the first bar (the image starts flush
    /// with it — no outer margin), a group gap at a provider boundary, otherwise the
    /// tight within-provider gap.
    private static func leadingGap(_ i: Int, in circles: [PieChart.Circle]) -> CGFloat {
        guard i > 0 else { return 0 }
        return circles[i].startsGroup ? groupGap : windowGap
    }

    /// The image is exactly as wide as the bars and their inter-bar gaps — no margin on
    /// either end, so the menu bar's own status-item padding is the only spacing around
    /// the row.
    static func size(circles: [PieChart.Circle]) -> NSSize {
        let total = circles.indices.reduce(CGFloat(0)) { w, i in
            w + leadingGap(i, in: circles) + slotWidth(circles[i])
        }
        return NSSize(width: max(barWidth, total), height: height + 2)
    }

    /// Compose a tray image straight from a view model.
    static func trayImage(from vm: TrayViewModel, now: Date = Date()) -> NSImage {
        image(circles: PieChart.circles(from: vm, now: now))
    }

    static func image(circles: [PieChart.Circle]) -> NSImage {
        // With nothing enabled/fetched, draw a single empty bar so the item stays visible.
        let drawn = circles.isEmpty
            ? [PieChart.Circle(kind: .pie(time: 0, usage: 0), caption: "",
                               usageColor: PieChart.spendPalette.usage,
                               timeColor: PieChart.spendPalette.time)]
            : circles
        let size = size(circles: drawn)
        let image = NSImage(size: size, flipped: false) { _ in
            let y = (size.height - height) / 2
            var x: CGFloat = 0
            for i in drawn.indices {
                x += leadingGap(i, in: drawn)
                let w = slotWidth(drawn[i])
                draw(drawn[i], in: NSRect(x: x, y: y, width: w, height: height))
                x += w
            }
            return true
        }
        image.isTemplate = false   // real colors, not a monochrome template
        return image
    }

    /// Draw a single slot: a bar, or the shared warning glyph for a failed provider.
    static func draw(_ circle: PieChart.Circle, in rect: NSRect) {
        switch circle.kind {
        case .pie(let time, let usage):
            drawBar(time: time, usage: usage, in: rect,
                    timeColor: circle.timeColor, usageColor: circle.usageColor)
        case .error:
            PieChart.drawErrorIcon(in: rect, color: circle.usageColor)
        }
    }

    /// Draw one bar from already-computed fractions. Exposed for previews/tests.
    static func drawBar(time: Double, usage: Double, in rect: NSRect,
                        timeColor: NSColor, usageColor: NSColor) {
        // Black backing rect — the untouched remainder, the bar's answer to the pie's disc.
        PieChart.disc.setFill()
        rect.fill()

        // Time: a dim column across the full width, filling bottom-up.
        let t = CGFloat(min(1, max(0, time)))
        timeColor.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * t).fill()

        // Usage: a bright stripe in the right-hand lane, over the time column. Clamped to
        // full height so an over-100% reading (shown in the text) never overfills the bar.
        // A soft dark shadow lifts the stripe off the time column behind it, the same trick
        // the pie's usage ring uses to sharpen the usage-vs-time contrast.
        let u = CGFloat(min(1, max(0, usage)))
        let stripe = NSRect(x: rect.maxX - usageWidth, y: rect.minY,
                            width: usageWidth, height: rect.height * u)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = .zero
        shadow.set()
        usageColor.setFill()
        stripe.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Hairline frame, last so nothing paints over it — bright white at 100%.
        frameColor(usage: usage).setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: hairlineWidth / 2, dy: hairlineWidth / 2))
        frame.lineWidth = hairlineWidth
        frame.stroke()
    }
}
