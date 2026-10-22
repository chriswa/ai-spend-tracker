import AppKit

/// A dropdown-menu header that shows a large version of the same circles drawn in
/// the status bar, laid out side by side. Under each ring, top to bottom: a heading
/// (the provider name, or the dollar value for the spend pie), the account row when any
/// provider reports accounts (the signed-in account underlined), the caption ("5-Hour",
/// "Spend", …), "Usage: n%" / "Elapsed: n%" lines, a "Reset: …" countdown, a
/// column-width sparkline of that metric's recent rate, and an "Updated: …" line (how
/// long ago that provider last fetched). Hover tooltips carry the extra detail:
/// projected usage on the pie, the absolute reset time on the reset line, and recent
/// peak on the sparkline. Clicking a provider column's "Updated" line copies that
/// provider's last raw response (for debugging / error reports). Fed a `PieChart.Circle`
/// list (built with `errorStyle: .staleData`, so an errored provider appears here as its
/// dimmed last-good pies, marked with a ⚠︎, rather than the tray's alert glyph). Draws
/// nothing until `circles` is set.
///
/// Columns wrap onto further rows rather than grow past `maxWidth`, breaking between
/// groups (a provider account's windows, the spend pie) so a group stays on one row
/// whenever it fits.
@MainActor
final class RingsHeaderView: NSView {
    /// The circles to render (in order); text/values/series come from each `Circle`.
    var circles: [PieChart.Circle] = [] {
        didSet { relayout() }
    }

    /// The widest the header may grow — beyond the menu's maximum width AppKit clips the
    /// header and truncates every other menu item. Set by `MenuBarController`.
    var maxWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if maxWidth != oldValue { relayout() } }
    }

    /// Each circle's (row, column) position, from `GridLayout.pack`.
    private var slots: [GridLayout.Slot] = []
    private var rowCount: Int { (slots.map(\.row).max() ?? -1) + 1 }
    private var columnsPerRow: Int { (slots.map(\.column).max() ?? -1) + 1 }

    private func relayout() {
        slots = GridLayout.pack(groupSizes: GridLayout.groupSizes(circles.map(\.startsGroup)),
                                maxColumns: maxColumns)
        setFrameSize(NSSize(width: preferredWidth, height: preferredHeight))
        rebuildTooltips()
        needsDisplay = true
    }

    /// The most columns whose row fits within `maxWidth` (at least one).
    private var maxColumns: Int {
        var n = max(1, circles.count)
        while n > 1, leftMargin * 2 + rowWidth(columns: n) > maxWidth { n -= 1 }
        return n
    }

    /// Invoked with a provider's raw response body when its "Updated" row is clicked.
    var onCopyRawResponse: ((String) -> Void)?

    // Layout (points).
    private let ringDiameter: CGFloat = 42
    private let columnWidth: CGFloat = 96   // per-circle column, wide enough for "Jul 22, 1:55 PM"
    /// Inter-column gap scales down with the columns per row but never below
    /// `minColumnGap`, so neighboring columns always keep a clear margin: 27pt at 2
    /// columns, 18 at 3, then held at the floor from 4 on. gap(n) = max(minColumnGap, 45 − 9n).
    private let minColumnGap: CGFloat = 14
    private func columnGap(columns n: Int) -> CGFloat { max(minColumnGap, 45 - 9 * CGFloat(n)) }
    private var columnGap: CGFloat { columnGap(columns: columnsPerRow) }
    private let rowGap: CGFloat = 14
    private let leftMargin: CGFloat = 21    // aligns with the standard menu-text indent
    private let minWidth: CGFloat = 220
    private let topPad: CGFloat = 12
    private let captionGap: CGFloat = 6      // ring → heading
    private let headingHeight: CGFloat = 14
    private let captionHeight: CGFloat = 15
    private let lineGap: CGFloat = 3         // between text lines
    private let statHeight: CGFloat = 13
    private let sparkTopGap: CGFloat = 6     // extra breathing room above the sparkline (~½ a text line)
    private let sparkHeight: CGFloat = 22
    private let updatedTopGap: CGFloat = 6    // sparkline → "Updated: …" line
    private let updatedHeight: CGFloat = 13
    private static let sparkGapThreshold: TimeInterval = 8 * 60

    private func rowWidth(columns n: Int) -> CGFloat {
        guard n > 0 else { return 0 }
        return CGFloat(n) * columnWidth + CGFloat(n - 1) * columnGap(columns: n)
    }
    var preferredWidth: CGFloat { max(minWidth, leftMargin + rowWidth(columns: columnsPerRow) + leftMargin) }
    /// Everything between the ring's bottom and the sparkline's top: heading, caption,
    /// and the three stat lines (Usage, Elapsed, Reset countdown), each preceded by its
    /// gap. The reset line is the last text line, so its bottom sits at
    /// `ringY - textBlockHeight`. Shared by the layout math, the reset tooltip rect,
    /// and the sparkline placement so they can't drift.
    private var textBlockHeight: CGFloat {
        captionGap + headingHeight
            + (hasAccountRow ? lineGap + accountHeight : 0)
            + lineGap + captionHeight
            + lineGap + statHeight   // Usage
            + lineGap + statHeight   // Elapsed
            + lineGap + statHeight   // Reset countdown
    }
    /// One row of columns, from the top of the ring to the bottom of the "Updated" line.
    private var rowHeight: CGFloat {
        ringDiameter + textBlockHeight + sparkTopGap + sparkHeight + updatedTopGap + updatedHeight
    }
    var preferredHeight: CGFloat {
        let rows = CGFloat(max(1, rowCount))
        return topPad + rows * rowHeight + (rows - 1) * rowGap + bottomPad
    }
    private let bottomPad: CGFloat = 8
    private let accountHeight: CGFloat = 13

    /// The account row is laid out only when some column names an account, so a user
    /// with a single login of every provider sees no empty row.
    private var hasAccountRow: Bool { circles.contains { $0.accountLabel != nil } }

    private static let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
    ]
    /// The caption for a stale (errored-but-shown) column — grayed like the stat lines so
    /// the whole column reads as inactive, reinforcing the dimmed pie and the ⚠︎ heading.
    private static let captionAttrsStale: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    /// The account row: the signed-in account in the label color, the others grayed.
    private static let accountAttrsActive: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
        .foregroundColor: NSColor.labelColor,
    ]
    private static let accountAttrsInactive: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    private static let statAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    /// The "Usage" line when the window is maxed (100%) — bright and bold, like the
    /// caption, so a capped window stands out from the grayed-out stat lines.
    private static let statAttrsFull: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard !circles.isEmpty else { return }
        let now = Date()

        for (i, circle) in circles.enumerated() {
            let rects = columnRects(index: i)
            let colX = rects.column
            PieChart.draw(circle, in: rects.ring)

            // Text lines, top-down, each centered in the column.
            var y = rects.ring.minY - captionGap - headingHeight
            if let heading = circle.heading {
                // Bold, in the pie's highlight color, to tie the column to its ring. A
                // stale column appends ⚠︎ so its best-effort/errored state is unmistakable.
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
                    .foregroundColor: circle.headingColor,
                ]
                drawLine(circle.isStale ? "\(heading) ⚠︎" : heading,
                         attrs: attrs, columnX: colX, bottomY: y, height: headingHeight)
            }
            if hasAccountRow {
                y -= lineGap + accountHeight
                if let account = circle.accountLabel {
                    drawLine(account, attrs: circle.marksActiveAccount ? Self.accountAttrsActive : Self.accountAttrsInactive,
                             columnX: colX, bottomY: y, height: accountHeight)
                }
                // Underline the active account across its columns, bridging the gap to
                // the next column when it belongs to the same run (as in the tray).
                if circle.marksActiveAccount {
                    let continues = i + 1 < circles.count && circles[i + 1].marksActiveAccount
                        && slots[i + 1].row == slots[i].row
                    NSColor.labelColor.setFill()
                    NSRect(x: colX, y: y - 1, width: columnWidth + (continues ? columnGap : 0), height: 1).fill()
                }
            }
            y -= lineGap + captionHeight
            drawLine(circle.caption, attrs: circle.isStale ? Self.captionAttrsStale : Self.captionAttrs,
                     columnX: colX, bottomY: y, height: captionHeight)

            // "Updated: 3m ago" / "47s ago" — how long ago this provider last fetched.
            // Drawn at a fixed slot below the sparkline band (whether or not a sparkline
            // drew), and for error columns too, so every column's last-fetch age is
            // visible and the row stays a stable click target for "copy last response".
            if let updated = circle.lastUpdated {
                drawLine("Updated: \(UsageMath.formatAgoShort(since: updated, now: now)) ago",
                         attrs: Self.statAttrs, columnX: colX,
                         bottomY: rects.updated.minY, height: updatedHeight)
            }

            guard case .pie(let time, let usage) = circle.kind else { continue }
            y -= lineGap + statHeight
            // A maxed window (100%) shows its Usage line bright/bold instead of grayed —
            // but a stale column stays grayed throughout, so it never shouts louder than
            // the live columns beside it.
            let usageAttrs = (usage >= 1 && !circle.isStale) ? Self.statAttrsFull : Self.statAttrs
            drawLine("Usage: \(pct(usage))%", attrs: usageAttrs, columnX: colX, bottomY: y, height: statHeight)
            y -= lineGap + statHeight
            drawLine("Elapsed: \(pct(time))%", attrs: Self.statAttrs, columnX: colX, bottomY: y, height: statHeight)
            y -= lineGap + statHeight
            drawLine(resetCountdown(circle.resetsAt, now: now), attrs: Self.statAttrs,
                     columnX: colX, bottomY: y, height: statHeight)

            // Column-width sparkline of the recent usage rate, below the stats.
            // Only drawn once there are ≥2 points (else it'd be an empty axis).
            guard circle.spark.count >= 2 else { continue }
            Sparkline.draw(points: UsageMath.usageRatePoints(circle.spark),
                           window: UsageHistory.sparklineWindow, now: now,
                           in: rects.spark, color: circle.usageColor,
                           background: .black,
                           gapThreshold: Self.sparkGapThreshold,
                           leftInset: 2, rightInset: 2, vInset: 3)
        }
    }

    /// The ring, reset-line, sparkline, and updated-line frames for column `i`, derived
    /// purely from the fixed layout so `draw`, `rebuildTooltips`, and click hit-testing
    /// place their targets identically.
    private func columnRects(index i: Int) -> (column: CGFloat, ring: NSRect, reset: NSRect,
                                               spark: NSRect, updated: NSRect) {
        let slot = slots[i]
        let ringY = bounds.height - topPad - CGFloat(slot.row) * (rowHeight + rowGap) - ringDiameter
        let colX = leftMargin + CGFloat(slot.column) * (columnWidth + columnGap)
        let ring = NSRect(x: colX + (columnWidth - ringDiameter) / 2, y: ringY,
                          width: ringDiameter, height: ringDiameter)
        let reset = NSRect(x: colX, y: ringY - textBlockHeight, width: columnWidth, height: statHeight)
        let spark = NSRect(x: colX, y: ringY - textBlockHeight - sparkTopGap - sparkHeight,
                           width: columnWidth, height: sparkHeight)
        let updated = NSRect(x: colX, y: spark.minY - updatedTopGap - updatedHeight,
                             width: columnWidth, height: updatedHeight)
        return (colX, ring, reset, spark, updated)
    }

    /// Live tooltip text keyed by the tag `addToolTip` returns. `addToolTip` does not
    /// retain its owner, so the strings must live here (owned by the view) rather than
    /// being passed as a temporary NSString — otherwise the owner is freed and AppKit
    /// messages a dangling pointer on hover.
    private var toolTipStrings: [NSView.ToolTipTag: String] = [:]

    /// Hover tooltips for each column's updated line (copy hint), pie (projected usage),
    /// reset line (absolute reset time), and sparkline (recent peak). Rebuilt whenever
    /// `circles` changes.
    private func rebuildTooltips() {
        removeAllToolTips()
        toolTipStrings.removeAll()
        guard !circles.isEmpty, bounds.height > 0 else { return }
        for (i, circle) in circles.enumerated() {
            let rects = columnRects(index: i)
            if circle.rawResponse != nil {
                addToolTip("Click to copy last response", in: rects.updated)
            }
            guard case .pie = circle.kind else { continue }
            addToolTip(circle.pieTooltip, in: rects.ring)
            addToolTip(resetTooltip(circle.resetsAt), in: rects.reset)
            if circle.spark.count >= 2 { addToolTip(circle.sparkTooltip, in: rects.spark) }
        }
    }

    /// A click on a provider column's "Updated" row copies that provider's last raw
    /// response. Columns without a recorded response (the spend pie, a provider that
    /// hasn't fetched) aren't click targets.
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (i, circle) in circles.enumerated() {
            guard let raw = circle.rawResponse else { continue }
            if columnRects(index: i).updated.contains(point) {
                onCopyRawResponse?(raw)
                return
            }
        }
        super.mouseUp(with: event)
    }

    /// Register one tooltip rect, owned by this view (see `toolTipStrings`). No-op when
    /// there's no text to show.
    private func addToolTip(_ text: String?, in rect: NSRect) {
        guard let text else { return }
        let tag = addToolTip(rect, owner: self, userData: nil)
        toolTipStrings[tag] = text
    }

    /// A column's live reset countdown ("Reset: 4d 19h"). An idle window (no reset
    /// yet) reads as "Reset: —"; one already past reads as "Reset: soon".
    private func resetCountdown(_ resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return "Reset: —" }
        if resetsAt.timeIntervalSince(now) <= 0 { return "Reset: soon" }
        return "Reset: \(UsageMath.formatDelta(to: resetsAt, now: now))"
    }

    /// The reset line's hover text — the absolute reset time ("Resets Jul 22, 2:00 PM"),
    /// or nil for an idle/elapsed window (nothing meaningful to show).
    private func resetTooltip(_ resetsAt: Date?) -> String? {
        guard let resetsAt, resetsAt.timeIntervalSince(Date()) > 0 else { return nil }
        return "Resets \(UsageMath.formatResetTime(resetsAt, now: Date()))"
    }

    private func pct(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

    private func drawLine(_ text: String, attrs: [NSAttributedString.Key: Any],
                          columnX x: CGFloat, bottomY: CGFloat, height: CGFloat) {
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: x + (columnWidth - size.width) / 2, y: bottomY + (height - size.height) / 2),
                 withAttributes: attrs)
    }
}

extension RingsHeaderView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTipStrings[tag] ?? ""
    }
}

/// Packs header columns into rows: groups are placed left to right and a group that
/// doesn't fit in the current row's remaining room starts a new row. A group wider than
/// a whole row is split across rows.
enum GridLayout {
    struct Slot: Equatable { var row: Int; var column: Int }

    /// Group sizes from each circle's `startsGroup` flag (a leading circle without the
    /// flag still opens the first group).
    static func groupSizes(_ startsGroup: [Bool]) -> [Int] {
        var sizes: [Int] = []
        for (i, starts) in startsGroup.enumerated() {
            if starts || i == 0 { sizes.append(1) } else { sizes[sizes.count - 1] += 1 }
        }
        return sizes
    }

    static func pack(groupSizes: [Int], maxColumns: Int) -> [Slot] {
        let width = max(1, maxColumns)
        var slots: [Slot] = []
        var row = 0, column = 0
        for size in groupSizes {
            if column > 0, column + size > width { row += 1; column = 0 }
            for _ in 0..<size {
                if column == width { row += 1; column = 0 }
                slots.append(Slot(row: row, column: column))
                column += 1
            }
        }
        return slots
    }
}
