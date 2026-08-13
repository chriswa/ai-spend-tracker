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
        case .rings: return TrayRings.image(circles: circles, outline: PieChart.outline(forDark: isDark))
        case .bars: return TrayBars.image(circles: circles)
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
