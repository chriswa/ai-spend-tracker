import AppKit

/// Dev-only: `AISpendTracker --render <out.png>` draws a grid of pie scenarios at
/// large scale (so the arcs are eyeball-verifiable) plus a menu-bar-size preview,
/// writes a PNG, and exits. Not used by the running app.
enum DebugRender {
    /// (title, time fraction, usage fraction)
    private static let cases: [(String, Double, Double)] = [
        ("empty (t0 u0)", 0.0, 0.0),
        ("time leads usage", 0.60, 0.45),
        ("usage leads time", 0.30, 0.50),
        ("equal", 0.50, 0.50),
        ("usage over 100%", 0.30, 1.13),
        ("nearly full time", 0.95, 0.80),
        ("tiny sliver time", 0.03, 0.0),
        ("full both", 1.0, 1.0),
    ]

    @MainActor
    static func run(outPath: String) {
        let cell: CGFloat = 160
        let pieD: CGFloat = 120
        let labelH: CGFloat = 24
        let cols = 4
        let rows = (cases.count + cols - 1) / cols
        let width = CGFloat(cols) * cell + 140   // extra room for the error-tray preview
        let height = CGFloat(rows) * (cell + labelH) + 80

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(white: 0.15, alpha: 1).setFill()
            rect.fill()

            for (i, c) in cases.enumerated() {
                let col = i % cols, row = i / cols
                let x = CGFloat(col) * cell
                let y = height - 80 - CGFloat(row + 1) * (cell + labelH) + labelH
                let pieRect = NSRect(x: x + (cell - pieD) / 2, y: y, width: pieD, height: pieD)
                let pal = PieChart.palette(for: .claude)
                PieChart.drawPie(time: c.1, usage: c.2, in: pieRect, timeColor: pal.time, usageColor: pal.usage, overColor: pal.over)
                drawLabel(c.0, centeredIn: NSRect(x: x, y: y - labelH, width: cell, height: labelH))
            }

            let now0 = Date()
            let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now0)) ?? now0
            let monthEnd = Calendar.current.date(byAdding: .month, value: 1, to: monthStart) ?? now0
            let claude = ProviderView(id: .claude, displayName: "Claude",
                snapshot: ProviderSnapshot(windows: [
                    UsageWindow(caption: "5-Hour", utilization: 72, resetsAt: now0.addingTimeInterval(2 * 3600),
                                timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
                    UsageWindow(caption: "7-Day", utilization: 40, resetsAt: now0.addingTimeInterval(5 * 24 * 3600),
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
                ], spend: SpendInfo(usedCents: 12345, apiLimitCents: 50000, label: "Claude extra usage")),
                lastUpdated: now0)

            // Draw the actual tray image scaled up so we see the true menu-bar look, in
            // the default ring style.
            let tray = TrayRings.trayImage(from: TrayViewModel(providers: [claude], customLimitCents: 250000), now: now0)
            let scale: CGFloat = 5
            let tw = tray.size.width * scale, th = tray.size.height * scale
            tray.draw(in: NSRect(x: 20, y: 20, width: tw, height: th),
                      from: .zero, operation: .sourceOver, fraction: 1)
            drawLabel("actual tray rings ×5", centeredIn: NSRect(x: 20, y: 20 + th, width: tw, height: 20))

            // A full house: every provider enabled (Claude with a scoped third window,
            // Devin with two, Codex errored) plus the spend bar — the layout that has to
            // stay narrow, and where the wider provider-boundary gaps must read.
            let claudeFull = ProviderView(id: .claude, displayName: "Claude",
                snapshot: ProviderSnapshot(windows: (claude.snapshot?.windows ?? []) + [
                    UsageWindow(caption: "Fable 7-Day", utilization: 61,
                                resetsAt: now0.addingTimeInterval(3 * 24 * 3600),
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay), isScoped: true),
                ], spend: claude.snapshot?.spend),
                lastUpdated: now0)
            let codexErr = ProviderView(id: .codex, displayName: "Codex", error: "Codex token expired")
            let cursor = ProviderView(id: .cursor, displayName: "Cursor",
                snapshot: ProviderSnapshot(windows: [
                    UsageWindow(caption: "Monthly", utilization: 18, resetsAt: monthEnd,
                                timeBasis: .interval(start: monthStart, end: monthEnd)),
                ], spend: SpendInfo(usedCents: 4200, apiLimitCents: 150000, label: "Cursor on-demand")),
                lastUpdated: now0)
            let devin = ProviderView(id: .devin, displayName: "Devin",
                snapshot: ProviderSnapshot(windows: [
                    UsageWindow(caption: "Daily", utilization: 104, resetsAt: now0.addingTimeInterval(9 * 3600),
                                timeBasis: .rollingWindow(length: 24 * 3600)),
                    UsageWindow(caption: "Weekly", utilization: 33, resetsAt: now0.addingTimeInterval(3 * 24 * 3600),
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
                ]),
                lastUpdated: now0)
            let errTray = TrayBars.trayImage(
                from: TrayViewModel(providers: [claudeFull, codexErr, cursor, devin], customLimitCents: 30000),
                now: now0)
            let ew = errTray.size.width * scale, eh = errTray.size.height * scale
            let ex = 20 + tw + 40
            errTray.draw(in: NSRect(x: ex, y: 20, width: ew, height: eh),
                         from: .zero, operation: .sourceOver, fraction: 1)
            drawLabel("all providers + error, bars ×5", centeredIn: NSRect(x: ex, y: 20 + eh, width: ew, height: 20))

            // Sparkline preview over a fixed 2-hour axis ending "now": an older
            // cluster, a gap (missed samples → broken line), then a recent cluster
            // ending at the right edge. Empty stretches stay empty (not stretched).
            let now = Date()
            func t(_ minAgo: Double) -> Date { now.addingTimeInterval(-minAgo * 60) }
            let samples: [(Date, Double)] = [
                (t(90), 10), (t(85), 12), (t(80), 20), (t(75), 24),          // older cluster
                (t(25), 30), (t(20), 46), (t(15), 50), (t(10), 51), (t(5), 70), (t(0), 78), // recent, after a gap
            ]
            let sparkRect = NSRect(x: 40, y: height - 56, width: 260, height: 36)
            Sparkline.draw(points: UsageMath.usageRatePoints(samples),
                           window: 2 * 60 * 60, now: now,
                           in: sparkRect, color: PieChart.palette(for: .claude).usage,
                           background: PieChart.palette(for: .claude).time,
                           gapThreshold: 8 * 60, leftInset: 6, rightInset: 6)
            drawLabel("usage-rate sparkline (fixed 2h axis, gaps left blank)",
                      centeredIn: NSRect(x: 40, y: height - 78, width: 360, height: 20))

            // Light-mode tray check: the same bars over a light bar, so their weight
            // against a pale menu bar reads next to the dark-backed trays above.
            let lightBar = NSRect(x: 440, y: height - 66, width: 300, height: 40)
            NSColor(white: 0.92, alpha: 1).setFill()
            NSBezierPath(roundedRect: lightBar, xRadius: 6, yRadius: 6).fill()
            // Rings are the style whose hairline adapts to the backdrop, so they are what
            // this check needs to draw.
            let lightTray = TrayRings.trayImage(from: TrayViewModel(providers: [claude], customLimitCents: 250000),
                                                now: now0, outline: PieChart.outline(forDark: false))
            let ls: CGFloat = 3
            lightTray.draw(in: NSRect(x: lightBar.minX + 10,
                                      y: lightBar.minY + (lightBar.height - lightTray.size.height * ls) / 2,
                                      width: lightTray.size.width * ls, height: lightTray.size.height * ls),
                           from: .zero, operation: .sourceOver, fraction: 1)
            drawLabel("light-mode rings (black hairline)",
                      centeredIn: NSRect(x: 440, y: height - 86, width: 300, height: 20))
            return true
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render: failed to encode PNG\n".utf8)); return
        }
        try? png.write(to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write(Data("render: wrote \(outPath)\n".utf8))

        renderHeader(baseOutPath: outPath)
    }

    /// Render the dropdown rings header (columns + reset lines + sparklines) to its
    /// own PNG, so the menu-open layout is eyeball-verifiable without launching.
    @MainActor
    private static func renderHeader(baseOutPath: String) {
        let now = Date()
        func t(_ minAgo: Double) -> Date { now.addingTimeInterval(-minAgo * 60) }
        // A rising utilization history so each window's sparkline has real data.
        func history(_ caption: String, _ base: Double, spend: Double? = nil) -> [UsageHistory.Sample] {
            [90, 75, 60, 45, 30, 15, 5, 0].enumerated().map { i, m in
                UsageHistory.Sample(date: t(Double(m)), windows: [caption: base + Double(i) * 4],
                                    spendCents: spend.map { $0 * Double(i + 1) })
            }
        }

        let claude = ProviderView(id: .claude, displayName: "Claude",
            snapshot: ProviderSnapshot(windows: [
                UsageWindow(caption: "5-Hour", utilization: 113, resetsAt: now.addingTimeInterval(2 * 3600),
                            timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
            ], spend: SpendInfo(usedCents: 12345, apiLimitCents: 50000, label: "Claude extra usage")),
            lastUpdated: now, history: history("5-Hour", 30, spend: 900))
        let cursor = ProviderView(id: .cursor, displayName: "Cursor",
            snapshot: ProviderSnapshot(windows: [
                UsageWindow(caption: "Weekly", utilization: 40,
                            resetsAt: now.addingTimeInterval(4 * 24 * 3600 + 19 * 3600),
                            timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
            ]),
            lastUpdated: now, history: history("Weekly", 12))

        // A low spend total so the combined spend pie reads over 100% (capped ring +
        // maxed dot, with the true percentage still shown in text).
        let vm = TrayViewModel(providers: [claude, cursor], customLimitCents: 10000)

        // Render both themes over a menu-like background, so light mode (adaptive text,
        // black pie rims) is verifiable alongside dark.
        let themes: [(NSAppearance.Name, CGFloat, String)] = [
            (.darkAqua, 0.18, "-header.png"),
            (.aqua, 0.96, "-header-light.png"),
        ]
        let base = (baseOutPath as NSString).deletingPathExtension
        for (name, bg, suffix) in themes {
            let header = RingsHeaderView(frame: .zero)
            header.appearance = NSAppearance(named: name)
            header.circles = PieChart.circles(from: vm, now: now, errorStyle: .staleData)
            header.setFrameSize(NSSize(width: header.preferredWidth, height: header.preferredHeight))
            guard let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) else { continue }
            header.cacheDisplay(in: header.bounds, to: rep)
            let out = NSImage(size: header.bounds.size, flipped: false) { rect in
                NSColor(white: bg, alpha: 1).setFill()
                rect.fill()
                if let cg = rep.cgImage { NSImage(cgImage: cg, size: rect.size).draw(in: rect) }
                return true
            }
            guard let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
                  let png = bmp.representation(using: .png, properties: [:]) else { continue }
            let path = base + suffix
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("render: wrote \(path)\n".utf8))
        }
    }

    private static func drawLabel(_ text: String, centeredIn rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}
