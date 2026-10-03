import Foundation

/// Pure geometry/formatting for the usage windows. Kept free of AppKit so it's
/// unit-testable and the pie renderer and menu text share one source of truth.
///
/// The two pie layers, both drawn from 12 o'clock clockwise:
///   • time layer  — fraction of the window that has elapsed (0 at window start,
///                    → 1 just before reset). Drawn as a gray wedge.
///   • usage layer  — utilization / 100. Drawn as a white ring over the time wedge.
enum UsageMath {
    /// Elapsed time and total span for a window, or nil when there's no time basis.
    /// For a rolling window elapsed = length − (resetsAt − now); an idle window
    /// (nil reset) reads as 0 elapsed. For an interval it's now−start over end−start.
    static func elapsedAndTotal(_ basis: TimeBasis, resetsAt: Date?,
                                now: Date = Date()) -> (elapsed: TimeInterval, total: TimeInterval)? {
        switch basis {
        case .rollingWindow(let length):
            guard let resetsAt else { return (0, length) }
            return (length - resetsAt.timeIntervalSince(now), length)
        case .interval(let start, let end):
            return (now.timeIntervalSince(start), end.timeIntervalSince(start))
        case .none:
            return nil
        }
    }

    /// Fraction of a window's span that has elapsed, clamped to 0…1 (the gray/dark
    /// time wedge). No time basis reads as 0.
    static func timeFraction(_ basis: TimeBasis, resetsAt: Date?, now: Date = Date()) -> Double {
        guard let (elapsed, total) = elapsedAndTotal(basis, resetsAt: resetsAt, now: now),
              total > 0 else { return 0 }
        return clamp01(elapsed / total)
    }

    /// Usage layer fraction (utilization is a 0…100 percentage) where 1.0 == 100%.
    /// Not clamped above 1 — it can read ≥100% in text; the pie clamps it for drawing.
    static func usageFraction(utilization: Double) -> Double {
        max(0, utilization / 100)
    }

    /// Minimum elapsed time before we show a projection (avoids wild early swings).
    static let projectionMinElapsed: TimeInterval = 10 * 60

    /// Linear extrapolation of end-of-window utilization, or nil when there isn't
    /// enough signal yet (too early, no usage, window already elapsed, or the window
    /// doesn't support projection). Can exceed 100 — that's the useful part of the
    /// warning. utilization × total / elapsed.
    static func projectUsage(_ window: UsageWindow, now: Date = Date()) -> Double? {
        guard window.supportsProjection, window.utilization > 0,
              let (elapsed, total) = elapsedAndTotal(window.timeBasis, resetsAt: window.resetsAt, now: now),
              elapsed >= projectionMinElapsed, elapsed < total else { return nil }
        return window.utilization * (total / elapsed)
    }

    // MARK: - Text formatting

    /// Reset time rounded to the nearest minute (the API gives second resolution;
    /// rounding to the hour was off by up to ~30 min). Includes the date when the
    /// reset is not today. e.g. "3:30 PM" or "Jul 19, 4:00 PM".
    static func formatResetTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let rounded = Date(timeIntervalSince1970:
            (date.timeIntervalSince1970 / 60).rounded() * 60)
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let time = timeFmt.string(from: rounded)
        if calendar.isDate(rounded, inSameDayAs: now) { return time }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d"
        return "\(dateFmt.string(from: rounded)), \(time)"
    }

    /// Human "time until reset", e.g. "48m", "2h 5m", "1d 2h", "now". Above a day
    /// we show days + hours (the 7-day window would otherwise read like "25h 50m").
    static func formatDelta(to date: Date, now: Date = Date()) -> String {
        let diff = date.timeIntervalSince(now)
        if diff <= 0 { return "now" }
        let totalMinutes = Int((diff / 60).rounded(.up))
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            return minutes > 0 ? "\(totalHours)h \(minutes)m" : "\(totalHours)h"
        }
        let days = totalHours / 24, hours = totalHours % 24
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }

    /// Fraction for the combined spend circle where 1.0 == 100%: total spend across
    /// providers over the user's spend total (always set, defaulting to $2500). Not
    /// clamped above 1 — it can read ≥100% in text; the pie clamps it for drawing.
    ///
    /// A $0 budget has no meaningful denominator, so the ring goes binary: empty at
    /// $0, full above. The time wedge behind it stays useful either way.
    static func spendFraction(usedCents: Double, limitCents: Double) -> Double {
        guard limitCents > 0 else { return usedCents > 0 ? 1 : 0 }
        return max(0, usedCents / limitCents)
    }

    /// Highest per-minute consumption rate across a cumulative series, and when it
    /// occurred. Each interval's rate is the (non-negative) rise divided by the
    /// actual minutes between those two samples — so it's correct even if sampling
    /// isn't exactly every 5 minutes. Returns nil if there was no positive usage.
    static func peakRatePerMinute(_ points: [(Date, Double)]) -> (perMinute: Double, at: Date)? {
        guard points.count >= 2 else { return nil }
        var best: (perMinute: Double, at: Date)?
        for i in 1..<points.count {
            let minutes = points[i].0.timeIntervalSince(points[i - 1].0) / 60
            guard minutes > 0 else { continue }
            let rate = max(0, points[i].1 - points[i - 1].1) / minutes
            if rate > 0, best == nil || rate > best!.perMinute {
                best = (rate, points[i].0)
            }
        }
        return best
    }

    /// Unit for a per-minute rate readout — utilization points or dollars.
    enum RateUnit { case percent, dollars }

    /// "Recent peak: 0.5%/min @ 1:00pm" (or "$0.30/min"), or nil without a positive
    /// rate in the series. Shown as the sparkline's tooltip.
    static func recentPeakText(_ points: [(Date, Double)], unit: RateUnit) -> String? {
        guard let peak = peakRatePerMinute(points) else { return nil }
        let rate: String
        switch unit {
        case .percent: rate = "\(trimmed(peak.perMinute, maxFractionDigits: 2))%"
        case .dollars: rate = String(format: "$%.2f", peak.perMinute / 100)
        }
        return "Recent peak: \(rate)/min @ \(formatClockCompact(peak.at))"
    }

    /// "Projected 87% at reset" — linear end-of-window extrapolation, or nil when
    /// there isn't enough signal yet. Shown as the pie's tooltip.
    static func projectedText(_ window: UsageWindow, now: Date = Date()) -> String? {
        guard let proj = projectUsage(window, now: now) else { return nil }
        return "Projected \(Int(proj.rounded()))% at reset"
    }

    /// Start of the next calendar month — when monthly spend resets. Drives the spend
    /// pie's reset readout.
    static func monthResetDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }

    /// A number with trailing-zero-trimmed decimals (e.g. 0.5000121 → "0.5",
    /// 1.0 → "1", 0.333… → "0.33"). Keeps rate readouts from looking like noise.
    static func trimmed(_ value: Double, maxFractionDigits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxFractionDigits
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Convert a cumulative time series (utilization %, or spend cents) into
    /// per-minute *rate* points for the sparkline, keeping each sample's timestamp
    /// so the line can be plotted on a real time axis. Each point is the
    /// (non-negative) rise since the previous sample divided by the minutes between
    /// them; the first point anchors the baseline at 0 (no predecessor), and drops
    /// (window resets, spend rollover) clamp to 0.
    static func usageRatePoints(_ samples: [(Date, Double)]) -> [(Date, Double)] {
        guard let first = samples.first else { return [] }
        var out: [(Date, Double)] = [(first.0, 0)]
        for i in 1..<samples.count {
            let minutes = samples[i].0.timeIntervalSince(samples[i - 1].0) / 60
            let rate = minutes > 0 ? max(0, samples[i].1 - samples[i - 1].1) / minutes : 0
            out.append((samples[i].0, rate))
        }
        return out
    }

    /// Fraction of the current calendar month that has elapsed (the spend "time"
    /// layer — spend limits reset monthly). Clamped to 0…1.
    static func monthTimeFraction(now: Date = Date(), calendar: Calendar = .current) -> Double {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return 0 }
        let total = nextMonth.timeIntervalSince(monthStart)
        guard total > 0 else { return 0 }
        return clamp01(now.timeIntervalSince(monthStart) / total)
    }

    /// Cents → "$42.50".
    static func formatDollars(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }

    /// Cents → "$0.000012138": every decimal place the Double carries (its shortest
    /// round-trip form), never scientific notation. For sub-cent readings `formatDollars`
    /// shows as $0.00.
    static func formatDollarsExact(_ cents: Double) -> String {
        let dollars = cents / 100
        return "$" + (Decimal(string: "\(dollars)")?.description ?? "\(dollars)")
    }

    /// Cents → "$43", rounded to the nearest dollar. Used for the compact tray glance;
    /// the dropdown keeps cent precision via `formatDollars`.
    static func formatDollarsRounded(_ cents: Double) -> String {
        String(format: "$%.0f", (cents / 100).rounded())
    }

    /// Compact lowercased time, e.g. "1:00pm" (for the recent-peak readout).
    static func formatClockCompact(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mma"
        return f.string(from: date).lowercased()
    }

    /// Compact single-unit "time since", e.g. "47s", "3m", "2h", "1d" — for the
    /// per-provider "Updated: …" line in the header, where space is tight and the
    /// leading unit is all the user needs. Sub-second (or future) reads as "0s".
    static func formatAgoShort(since date: Date, now: Date = Date()) -> String {
        let diff = max(0, now.timeIntervalSince(date))
        if diff < 60 { return "\(Int(diff))s" }
        let minutes = Int(diff / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}
