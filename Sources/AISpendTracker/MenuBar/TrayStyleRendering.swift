import AppKit

/// The one place the two tray renderers are chosen between. Everything upstream works in
/// `PieChart.Circle`s and never learns which style is active, so a reading can't come out
/// different depending on the shape it's drawn in — only its layout can.
extension TrayStyle {
    /// Compose the tray image in this style. `isDark` is the menu bar's appearance, which
    /// only rings care about: a ring's hairline lies against the bar itself, while a bar's
    /// frame sits on its own black backing (see `PieChart.outline(forDark:)`).
    func image(circles: [PieChart.Circle], isDark: Bool) -> NSImage {
        switch self {
        case .rings: return TrayRings.image(circles: circles, isDark: isDark)
        case .bars: return TrayBars.image(circles: circles, isDark: isDark)
        }
    }

    /// Menu label for this style, in menu order.
    var label: String {
        switch self {
        case .rings: return "Rings"
        case .bars: return "Bars"
        }
    }
}

/// The underline both tray styles draw beneath the active account's glyphs, when a
/// provider has more than one account (see `PieChart.Circle.marksActiveAccount`). It sits
/// on the menu bar itself, so it takes the bar's foreground color — white on dark, black
/// on light.
enum ActiveAccountUnderline {
    /// Extra image height reserved beneath the glyphs for the underline.
    static let reservedHeight: CGFloat = 2
    static let thickness: CGFloat = 1.5

    /// Whether any circle needs the underline (and so the reserved height).
    static func isNeeded(_ circles: [PieChart.Circle]) -> Bool {
        circles.contains { $0.marksActiveAccount }
    }

    /// Underline each consecutive run of active-account circles, spanning from the first
    /// slot's left edge to the last's right edge, at the bottom of the image.
    static func draw(circles: [PieChart.Circle], slots: [NSRect], isDark: Bool) {
        NSColor(white: isDark ? 1 : 0, alpha: 0.9).setFill()
        var i = 0
        while i < circles.count {
            guard circles[i].marksActiveAccount else { i += 1; continue }
            var j = i
            while j + 1 < circles.count, circles[j + 1].marksActiveAccount { j += 1 }
            NSRect(x: slots[i].minX, y: 0, width: slots[j].maxX - slots[i].minX, height: thickness).fill()
            i = j + 1
        }
    }
}
