import Foundation

/// `AISpendTracker --json`: prints the same readings the dropdown shows, as JSON, for
/// scripts and agents. Reads only what the running app has persisted (it never fetches),
/// so each provider's `updatedAt` says how fresh its numbers are.
enum UsageReport {
    struct Report: Encodable {
        var generatedAt: Date
        var providers: [Provider]
        /// Combined month-to-date spend; nil when no enabled provider reports spend.
        var spend: Spend?
    }

    struct Provider: Encodable {
        var id: String
        var name: String
        /// Last successful fetch. Every reading below is as of this instant.
        var updatedAt: Date?
        /// Set after repeated fetch failures; `windows` then holds the last good reading.
        var error: String?
        var warning: String?
        var windows: [Window]
        var spend: ProviderSpend?
    }

    struct Window: Encodable {
        var caption: String
        var usagePercent: Double
        var elapsedPercent: Double
        /// Linear end-of-window extrapolation; nil when there's too little signal.
        var projectedUsagePercent: Double?
        var resetsAt: Date?
        /// A per-model window (e.g. "Fable 7-Day") rather than an account-wide one.
        var modelScoped: Bool
    }

    struct ProviderSpend: Encodable {
        var label: String
        /// Spend attributed to the local calendar month — the figure the menu shows.
        var monthToDateUSD: Double
        /// The provider's own reading against its billing cycle, before reconciliation.
        var providerReportedUSD: Double
        var providerCycleResetsAt: Date?
        /// Why the month's figure may be off, when it may be.
        var uncertainty: String?
    }

    struct Spend: Encodable {
        var monthToDateUSD: Double
        /// Nil when no budget is set.
        var budgetUSD: Double?
        var percentOfBudget: Double?
        var monthElapsedPercent: Double
        var resetsAt: Date?
    }

    static func build(from vm: TrayViewModel, now: Date = Date()) -> Report {
        let providers = vm.providers.map { p -> Provider in
            let at = p.lastUpdated ?? now
            let windows = (p.snapshot?.windows ?? []).map { w in
                Window(caption: w.caption,
                       usagePercent: w.utilization,
                       elapsedPercent: rounded(UsageMath.timeFraction(w.timeBasis, resetsAt: w.resetsAt, now: at) * 100),
                       projectedUsagePercent: UsageMath.projectUsage(w, now: at).map(rounded),
                       resetsAt: w.resetsAt,
                       modelScoped: w.isScoped)
            }
            let spend = p.snapshot?.spend.map { s in
                let e = p.reconstructedSpend
                return ProviderSpend(label: s.label,
                                     monthToDateUSD: dollars(e?.monthSpendCents ?? s.usedCents),
                                     providerReportedUSD: dollars(s.usedCents),
                                     providerCycleResetsAt: s.cycleResetsAt,
                                     uncertainty: (e?.isMonthUncertain ?? false)
                                         ? (e?.monthUncertainReason ?? "This month's figure may be inaccurate.") : nil)
            }
            return Provider(id: p.id.rawValue, name: p.displayName, updatedAt: p.lastUpdated,
                            error: p.error, warning: p.snapshot?.warning, windows: windows, spend: spend)
        }

        var spend: Spend?
        if vm.hasAnySpend {
            let total = vm.combinedSpendCents
            let hasBudget = vm.customLimitCents > 0
            spend = Spend(monthToDateUSD: dollars(total),
                          budgetUSD: hasBudget ? dollars(vm.customLimitCents) : nil,
                          percentOfBudget: hasBudget ? rounded(total / vm.customLimitCents * 100) : nil,
                          monthElapsedPercent: rounded(UsageMath.monthTimeFraction(now: now) * 100),
                          resetsAt: UsageMath.monthResetDate(now: now))
        }
        return Report(generatedAt: now, providers: providers, spend: spend)
    }

    /// Dates as ISO 8601 in the local time zone, so they read naturally and still parse.
    static func encode(_ report: Report) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(iso.string(from: date))
        }
        return try encoder.encode(report)
    }

    /// Print the report for every enabled provider from the app's persisted state.
    @MainActor
    static func run() {
        let store = UsageStore()
        let ledger = SpendLedger()
        let providers = ProviderID.allCases.filter { Settings.enabledProviders.contains($0) }.map { id in
            ProviderView(id: id, displayName: id.displayName, snapshot: store.snapshot(id),
                         lastUpdated: store.lastSuccessAt(id), error: store.visibleError(id),
                         reconstructedSpend: ledger.entry(id))
        }
        let vm = TrayViewModel(providers: providers, customLimitCents: Settings.customLimitCents)
        do {
            FileHandle.standardOutput.write(try encode(build(from: vm)))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("failed to encode report: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func dollars(_ cents: Double) -> Double { (cents).rounded() / 100 }
    private static func rounded(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
