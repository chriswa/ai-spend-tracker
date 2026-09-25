import AppKit

/// Builds the ordered `Circle` list that drives both the status-item image and the
/// dropdown header, and draws the circle form of one. The header always draws rings;
/// the tray lays the same list out as rings or bars per `TrayStyle` (see `TrayRings`
/// and `TrayBars`). Each provider
/// contributes its window pies, in `ProviderID` order, followed by the combined spend
/// pie. A provider whose latest fetch failed renders per the caller's `ErrorStyle`:
/// the tray shows one compact warning glyph, while the header keeps its last good pies
/// dimmed and flagged (best-effort stale data) — the one place the two intentionally
/// diverge, because the header has room to show detail the cramped tray does not.
///
/// Each pie draws two independent layers, both filling clockwise from 12 o'clock:
///   1. a black disc (the empty remainder),
///   2. the "time" layer as a solid wedge [0 … time] across the full radius,
///   3. the "usage" layer as a ring [0 … usage] in the outer lane, over the wedge,
///   4. a thin hairline outline.
/// Colors come from the per-provider palette (usage ring + darkened time wedge);
/// the spend pie uses a green ring over a dimmed-green wedge.
enum PieChart {
    /// A provider's (or the spend pie's) colors: the bright usage ring, the dim time
    /// wedge, and the `over` mark drawn as a full outer ring at ≥100%. `over` is white
    /// for every palette; keeping it in the struct is the single source of truth for the
    /// maxed-out color — the draw code never infers it from the ring color.
    struct Palette { let usage: NSColor; let time: NSColor; let over: NSColor }

    /// Per-provider palette: usage ring in the brand color, time wedge at 50%
    /// brightness. Claude #D97757, Codex #3D93D6, Cursor #AC7CE0, Devin #D63D6E,
    /// Jev #26B8C9. Devin's raspberry sits in the open rose/magenta gap — kept well
    /// clear of the spend green (a different category, real money) and maximally
    /// separated from the other provider hues. Jev draws no ring (spend only), so its
    /// teal only tints menu text and its error glyph.
    static func palette(for id: ProviderID) -> Palette {
        switch id {
        case .claude: return make(217, 119, 87)
        case .codex:  return make(61, 147, 214)
        case .cursor: return make(172, 124, 224)
        case .devin:  return make(214, 61, 110)
        case .jev:    return make(38, 184, 201)
        }
    }
    /// Combined spend pie: a green usage ring (#34C759 — matched in perceived brightness
    /// to the brand colors) over a 50%-dimmed green time wedge, with a white maxed-out
    /// ring. A plain provider-style palette; the dollar figure is drawn in the same green.
    static let spendPalette = make(52, 199, 89)

    /// Claude's per-model scoped windows (e.g. "Fable 7-Day") render golden-amber so
    /// they read as distinct from the primary 5-hour/7-day windows, which keep Claude's
    /// orange. #E0A82E — a warm, saturated gold that sits harmoniously beside the brand
    /// colors; its 50%-dimmed time wedge lands on a rich bronze rather than muddy olive.
    static let scopedPalette = make(224, 168, 46)

    private static func make(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Palette {
        Palette(usage: NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1),
                time: NSColor(srgbRed: r / 255 * 0.5, green: g / 255 * 0.5, blue: b / 255 * 0.5, alpha: 1),
                over: .white)
    }

    /// A dimmed version of a palette for a provider's *stale* pies — the last good
    /// reading kept on screen when the latest fetch errored. The brand hue survives so
    /// the column still reads as that provider, but everything is darkened toward the
    /// black disc so it clearly looks inactive; the maxed-out ring drops from white to a
    /// muted gray so a capped stale window doesn't shout for attention.
    static func dimmed(_ p: Palette) -> Palette {
        Palette(usage: dim(p.usage, 0.5), time: dim(p.time, 0.6), over: dim(p.over, 0.45))
    }

    private static func dim(_ c: NSColor, _ factor: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return NSColor(srgbRed: s.redComponent * factor, green: s.greenComponent * factor,
                       blue: s.blueComponent * factor, alpha: 1)
    }

    // Untouched remainder — black.
    static let disc = NSColor.black
    // Subtle hairline ring rather than a bold white edge. The default suits a dark
    // backdrop (the menu header, and the menu bar in dark mode); the tray passes a
    // dark hairline in light mode via `outline(forDark:)`.
    static let outline = NSColor(white: 1, alpha: 0.5)

    /// Hairline color for a given backdrop: white on dark, black on light — a faint
    /// separator either way. Ring tray images pick this from the menu bar's appearance,
    /// since a ring's hairline lies against the bar; a bar's frame sits on its own black
    /// backing and needs no such adaptation.
    static func outline(forDark isDark: Bool) -> NSColor {
        NSColor(white: isDark ? 1 : 0, alpha: 0.5)
    }

    /// Thickness of the solid black rim around each pie, as a fraction of the radius
    /// (with an absolute floor). The rim vanishes into a dark background but separates
    /// the pie from a pale menu in light mode. Used by the menu rings, not the tray.
    static let borderRatio: CGFloat = 0.12
    static let borderMinWidth: CGFloat = 1

    // Geometry (points).
    static let outlineWidth: CGFloat = 0.5
    /// Inner edge of the usage ring, as a fraction of the pie radius (so the ring band
    /// is the outer 1/3 of the radius).
    static let ringInnerRatio: CGFloat = 0.67
    /// Width of the bright "maxed out" ring (drawn at 100% around the very outside of
    /// the pie), as a fraction of the pie radius. Kept well under the usage lane's 1/3
    /// so the usage color still shows through inside it.
    static let fullRingWidthRatio: CGFloat = 1.0 / 16.0

    /// One circle: either a two-layer pie or a warning glyph (failed provider). The
    /// single source of truth shared by the tray image and the dropdown header, so
    /// the two never disagree about which slots to show or what they represent.
    struct Circle {
        enum Kind: Equatable {
            case pie(time: Double, usage: Double)
            case error
        }
        var kind: Kind
        /// The provider's last raw response body, or nil for the combined spend circle
        /// (and providers that haven't recorded one). Header-only: makes the column's
        /// "Updated" row copyable. Unused by the tray image.
        var rawResponse: String?
        /// Optional line drawn above the caption in the dropdown header: the provider
        /// name for a window/error circle, or the dollar value for the spend circle.
        /// Unused by the tray image.
        var heading: String?
        var caption: String
        var usageColor: NSColor
        var timeColor: NSColor
        /// Color of the "maxed out" ring drawn around the outside at ≥100% usage. Comes
        /// straight from the palette (white for every pie) — never derived from `usageColor`.
        var overColor: NSColor
        /// Color for the heading text in the dropdown header. Usually the usage color
        /// (ties the column to its ring), but the spend column diverges: its ring sits
        /// on a black disc (neutral = white) while the heading sits on the menu
        /// background (neutral = the adaptive label color). Header-only.
        var headingColor: NSColor
        /// Cumulative series (utilization % or spend cents, oldest first) feeding the
        /// per-column sparkline in the dropdown header. Unused by the tray image.
        var spark: [(Date, Double)]
        /// When this window/pie next resets (nil for an idle window). Drives the
        /// header column's "Reset: …" lines, computed live against the clock.
        var resetsAt: Date?
        /// When this circle's provider last fetched successfully — drives the header
        /// column's live "Updated: …" line. For the spend circle it's the newest fetch
        /// across providers. Header-only.
        var lastUpdated: Date?
        /// Hover text for the pie (projected end-of-window usage) and the sparkline
        /// (recent peak rate), or nil when there isn't enough signal. Header-only.
        var pieTooltip: String?
        var sparkTooltip: String?
        /// Whether this pie is a stale best-effort reading shown because the provider's
        /// latest fetch errored (its colors are already dimmed via `dimmed(_:)`). The
        /// dropdown header flags such columns with a ⚠︎ so the staleness is unmistakable;
        /// the tray never emits these (it keeps the compact error glyph). Header-only.
        var isStale: Bool
        /// Whether this circle opens a new group — the first of a provider's windows, or
        /// the combined spend circle. Set here, at the one place that knows which provider
        /// each circle came from, so the tray can widen the gap at provider boundaries
        /// without re-deriving ownership from captions. Tray-only; the header spaces its
        /// columns evenly.
        var startsGroup: Bool

        init(kind: Kind, rawResponse: String? = nil, heading: String? = nil, caption: String,
             usageColor: NSColor, timeColor: NSColor, overColor: NSColor = .white,
             headingColor: NSColor? = nil,
             spark: [(Date, Double)] = [],
             resetsAt: Date? = nil, lastUpdated: Date? = nil,
             pieTooltip: String? = nil, sparkTooltip: String? = nil,
             isStale: Bool = false, startsGroup: Bool = false) {
            self.kind = kind
            self.rawResponse = rawResponse
            self.heading = heading
            self.caption = caption
            self.usageColor = usageColor
            self.timeColor = timeColor
            self.overColor = overColor
            self.headingColor = headingColor ?? usageColor
            self.spark = spark
            self.resetsAt = resetsAt
            self.lastUpdated = lastUpdated
            self.pieTooltip = pieTooltip
            self.sparkTooltip = sparkTooltip
            self.isStale = isStale
            self.startsGroup = startsGroup
        }
    }

    /// How a provider whose latest fetch errored is drawn.
    ///   • `glyph` — one compact warning triangle in the provider's slot (the tray:
    ///     space-constrained, so the alert glyph is the whole signal).
    ///   • `staleData` — its last good windows redrawn as dimmed "stale" pies (the
    ///     dropdown header: room to show best-effort data, flagged with a ⚠︎ and backed
    ///     by the error message in the section below). Falls back to `glyph` when there's
    ///     no retained snapshot to show.
    enum ErrorStyle { case glyph, staleData }

    /// The ordered circles for a tray view model: each enabled provider's window pies,
    /// then the combined spend pie when any provider reports spend. A provider that
    /// hasn't fetched yet contributes nothing. An errored provider renders per
    /// `errorStyle` — a single warning glyph (tray) or its dimmed last-good pies (header).
    ///
    /// Each window's time wedge is computed at *that provider's* last-fetch moment
    /// (`lastUpdated`), not the live clock, so time never races ahead of the frozen
    /// usage reading and the time-vs-usage comparison stays fair between fetches.
    ///
    /// `includeSpend` gates the trailing spend pie: the tray drops it in text/off
    /// display mode (the figure is drawn as the button title instead, or hidden),
    /// while the dropdown header always passes `true` to keep the rich spend column.
    static func circles(from vm: TrayViewModel, now: Date = Date(),
                        includeSpend: Bool = true, errorStyle: ErrorStyle = .glyph) -> [Circle] {
        var out: [Circle] = []
        for p in vm.providers {
            let pal = palette(for: p.id)
            if p.error != nil, errorStyle == .staleData, let snap = p.snapshot, !snap.windows.isEmpty {
                out += windowCircles(for: p, snapshot: snap, providerPalette: pal, now: now, stale: true)
            } else if p.error != nil {
                out.append(Circle(kind: .error, rawResponse: p.lastRawResponse,
                                  heading: p.displayName, caption: "unavailable",
                                  usageColor: pal.usage, timeColor: pal.time, lastUpdated: p.lastUpdated,
                                  startsGroup: true))
            } else if let snap = p.snapshot {
                out += windowCircles(for: p, snapshot: snap, providerPalette: pal, now: now, stale: false)
            }
        }
        if includeSpend && vm.hasAnySpend {
            let at = vm.latestUpdate ?? now
            out.append(Circle(
                kind: .pie(time: UsageMath.monthTimeFraction(now: at),
                           usage: UsageMath.spendFraction(usedCents: vm.combinedSpendCents,
                                                          limitCents: vm.customLimitCents)),
                heading: UsageMath.formatDollars(vm.combinedSpendCents), caption: "Spend",
                // A standard provider-style pie: green ring, green heading text, no pace
                // tint — matching how every other provider column is colored.
                usageColor: spendPalette.usage,
                timeColor: spendPalette.time,
                overColor: spendPalette.over,
                headingColor: spendPalette.usage,
                spark: vm.spendSeries,
                resetsAt: UsageMath.monthResetDate(now: now),
                lastUpdated: vm.latestUpdate,
                sparkTooltip: UsageMath.recentPeakText(vm.spendSeries, unit: .dollars),
                startsGroup: true))
        }
        return out
    }

    /// One pie per window in a provider's snapshot, sharing the exact same layout for
    /// live and stale readings. When `stale` is set the palette is dimmed and the circle
    /// is flagged `isStale`, so a best-effort reading after a failed fetch differs from a
    /// healthy one only in appearance — never in which columns or detail it shows.
    private static func windowCircles(for p: ProviderView, snapshot snap: ProviderSnapshot,
                                      providerPalette pal: Palette, now: Date, stale: Bool) -> [Circle] {
        let at = p.lastUpdated ?? now
        return snap.windows.enumerated().map { i, w in
            let series = p.series(forWindow: w.caption)
            let base = w.isScoped ? scopedPalette : pal
            let wpal = stale ? dimmed(base) : base
            return Circle(
                kind: .pie(time: UsageMath.timeFraction(w.timeBasis, resetsAt: w.resetsAt, now: at),
                           usage: UsageMath.usageFraction(utilization: w.utilization)),
                rawResponse: p.lastRawResponse, heading: p.displayName, caption: w.caption,
                usageColor: wpal.usage, timeColor: wpal.time, overColor: wpal.over,
                spark: series,
                resetsAt: w.resetsAt,
                lastUpdated: p.lastUpdated,
                pieTooltip: UsageMath.projectedText(w, now: at),
                sparkTooltip: UsageMath.recentPeakText(series, unit: .percent),
                isStale: stale, startsGroup: i == 0)
        }
    }

    /// Draw a single circle (pie or warning glyph). Shared by the dropdown header and
    /// the ring-style tray, keeping the two in lockstep. `bordered` draws the black rim
    /// (menu only); `outline` is the hairline color.
    static func draw(_ circle: Circle, in rect: NSRect, bordered: Bool = true, outline: NSColor = Self.outline) {
        switch circle.kind {
        case .pie(let time, let usage):
            drawPie(time: time, usage: usage, in: rect, timeColor: circle.timeColor,
                    usageColor: circle.usageColor, overColor: circle.overColor,
                    bordered: bordered, outline: outline)
        case .error:
            drawErrorIcon(in: rect, color: circle.usageColor)
        }
    }

    /// Draw a warning triangle (failed-fetch indicator) fitted to `rect`, tinted in
    /// the provider's color.
    static func drawErrorIcon(in rect: NSRect, color: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "fetch error")?
            .withSymbolConfiguration(cfg) else { return }
        let s = symbol.size
        let scale = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        let dst = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        let tinted = NSImage(size: dst.size, flipped: false) { r in
            symbol.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Draw one circle from already-computed fractions. Exposed for previews/tests.
    /// `bordered` leaves a black rim inside the disc (menu only).
    static func drawPie(time: Double, usage: Double, in rect: NSRect,
                        timeColor: NSColor, usageColor: NSColor, overColor: NSColor = .white,
                        bordered: Bool = true, outline: NSColor = Self.outline) {
        let inset = outlineWidth / 2 + 0.25
        let rOuter = min(rect.width, rect.height) / 2 - inset
        let center = NSPoint(x: rect.midX, y: rect.midY)

        // Black backing disc at the full radius. When bordered, the colored content is
        // drawn inside a thinner radius so the annulus stays black — the pie's rim,
        // which separates it from a pale background in the menu.
        disc.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - rOuter, y: center.y - rOuter,
                                    width: 2 * rOuter, height: 2 * rOuter)).fill()
        let r = bordered ? rOuter - max(borderMinWidth, rOuter * borderRatio) : rOuter

        // Time: a solid wedge spanning the whole radius (both lanes).
        fillWedge(center: center, radius: r, from: 0, to: time, color: timeColor)
        // Usage: a ring in the outer lane, over the time wedge. Clamped to one full turn
        // so an over-100% reading (shown in the text) never overfills the pie. A soft dark
        // shadow cast under the ring lifts it off the time wedge behind it, sharpening the
        // usage-vs-time contrast; the blur scales with the pie so it reads at any size.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowBlurRadius = max(0.75, r * 0.12)
        shadow.shadowOffset = .zero
        shadow.set()
        fillRingWedge(center: center, innerRadius: r * ringInnerRatio, outerRadius: r,
                      from: 0, to: min(1, max(0, usage)), color: usageColor)
        NSGraphicsContext.restoreGraphicsState()

        strokeOutline(center: center, radius: r, color: outline)

        // At ≥100% the ring is full; overlay a bright full ring around the very outside
        // as a "maxed" flag, sitting inside the outer 1/3 usage lane so the usage color
        // still shows through beneath it. Applies to every pie, spend included. The mark
        // color comes from the palette (white), never inferred from the ring color.
        if usage >= 1 {
            let width = r * fullRingWidthRatio
            fillRingWedge(center: center, innerRadius: r - width, outerRadius: r,
                          from: 0, to: 1, color: overColor)
        }
    }

    private static func strokeOutline(center: NSPoint, radius r: CGFloat, color: NSColor = outline) {
        color.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = outlineWidth
        ring.stroke()
    }

    /// Point on the circle of radius `r` about `center` at fraction `f`, measured
    /// clockwise from 12 o'clock.
    private static func arcPoint(center: NSPoint, radius r: CGFloat, fraction f: Double) -> NSPoint {
        let angle = (90.0 - f * 360.0) * .pi / 180.0
        return NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }

    /// Fill a pie wedge spanning fractions [a, b], measured clockwise from 12 o'clock.
    private static func fillWedge(center: NSPoint, radius r: CGFloat,
                                  from a: Double, to b: Double, color: NSColor) {
        guard b > a, r > 0 else { return }
        let path = NSBezierPath()
        path.move(to: center)
        let steps = max(2, Int((b - a) * 360))
        for i in 0...steps {
            path.line(to: arcPoint(center: center, radius: r, fraction: a + (b - a) * Double(i) / Double(steps)))
        }
        path.close()
        color.setFill()
        path.fill()
    }

    /// Fill an annular (ring) wedge spanning fractions [a, b] between `innerR` and
    /// `outerR`, clockwise from 12 o'clock.
    private static func fillRingWedge(center: NSPoint, innerRadius innerR: CGFloat, outerRadius outerR: CGFloat,
                                      from a: Double, to b: Double, color: NSColor) {
        guard b > a, outerR > innerR, innerR >= 0 else { return }
        let path = NSBezierPath()
        let steps = max(2, Int((b - a) * 360))
        for i in 0...steps {
            let f = a + (b - a) * Double(i) / Double(steps)
            let p = arcPoint(center: center, radius: outerR, fraction: f)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            path.line(to: arcPoint(center: center, radius: innerR, fraction: a + (b - a) * Double(i) / Double(steps)))
        }
        path.close()
        color.setFill()
        path.fill()
    }
}
