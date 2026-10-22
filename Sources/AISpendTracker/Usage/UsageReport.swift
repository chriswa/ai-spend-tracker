import Foundation

/// `AISpendTracker --json`: prints the same readings the dropdown shows, as JSON, for
/// scripts and agents. Reads only what the running app has persisted (it never fetches),
/// so each provider's `updatedAt` says how fresh its numbers are.
///
/// Only the signed-in account of each provider is reported by default, so a reader can
/// take every entry as current. `--all-accounts` adds the other accounts, each marked
/// `signedIn: false` with a `note` saying its numbers are carried forward.
enum UsageReport {
    struct Report: Encodable {
        var generatedAt: Date
        var providers: [Provider]
        /// Combined month-to-date spend across every account, signed in or not; nil when
        /// no enabled provider reports spend.
        var spend: Spend?
        /// Accounts left out of `providers` because they aren't signed in ("Claude:
        /// Spare"); pass `--all-accounts` to include them. Nil when none were left out.
        var omittedAccounts: [String]?
    }

    /// One entry per reported provider account; a provider without accounts has one.
    struct Provider: Encodable {
        var id: String
        var name: String
        /// The account this reading is from, for providers that report one.
        var account: String?
        /// Whether `account` is the one currently signed in; nil for providers without
        /// accounts. Only false with `--all-accounts`.
        var signedIn: Bool?
        /// Set on an account that isn't signed in, explaining that its numbers are stale.
        var note: String?
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

    static let inactiveAccountNote = "NOT the signed-in account. These numbers are its last reading, "
        + "carried forward assuming no use since (windows read 0% once their reset passes); "
        + "it can't be refreshed until the user signs back into it. Usage here does not limit the signed-in account."

    static func build(from vm: TrayViewModel, now: Date = Date(), includeInactiveAccounts: Bool = false) -> Report {
        let omitted = includeInactiveAccounts ? [] : vm.providers.flatMap { p in
            p.accounts.filter { !$0.isActive }.compactMap { a in a.account.map { "\(p.displayName): \($0.label)" } }
        }
        let providers = vm.providers.flatMap { p -> [Provider] in
            // A provider that has never fetched still gets an entry, carrying its error.
            guard !p.accounts.isEmpty else {
                return [Provider(id: p.id.rawValue, name: p.displayName, updatedAt: p.lastUpdated,
                                 error: p.error, warning: nil, windows: [], spend: nil)]
            }
            return p.accounts.filter { includeInactiveAccounts || $0.isActive }.map { a in
                let at = a.timeAnchor(now: now)
                let windows = a.windows(now: now).map { w in
                    Window(caption: w.caption,
                           usagePercent: w.utilization,
                           elapsedPercent: rounded(UsageMath.timeFraction(w.timeBasis, resetsAt: w.resetsAt, now: at) * 100),
                           projectedUsagePercent: a.isActive ? UsageMath.projectUsage(w, now: at).map(rounded) : nil,
                           resetsAt: w.resetsAt,
                           modelScoped: w.isScoped)
                }
                let spend = a.snapshot.spend.map { s in
                    let e = a.reconstructedSpend
                    return ProviderSpend(label: s.label,
                                         monthToDateUSD: dollars(a.monthSpendCents(now: now) ?? s.usedCents),
                                         providerReportedUSD: dollars(s.usedCents),
                                         providerCycleResetsAt: s.cycleResetsAt,
                                         uncertainty: (e?.isMonthUncertain ?? false)
                                             ? (e?.monthUncertainReason ?? "This month's figure may be inaccurate.") : nil)
                }
                return Provider(id: p.id.rawValue, name: p.displayName, account: a.account?.label,
                                signedIn: a.account == nil ? nil : a.isActive,
                                note: a.isActive ? nil : inactiveAccountNote,
                                updatedAt: a.lastUpdated, error: a.isActive ? p.error : nil,
                                warning: a.snapshot.warning, windows: windows, spend: spend)
            }
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
        return Report(generatedAt: now, providers: providers, spend: spend,
                      omittedAccounts: omitted.isEmpty ? nil : omitted)
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
    static func run(includeInactiveAccounts: Bool) {
        let store = UsageStore()
        let ledger = SpendLedger()
        let providers = ProviderID.allCases.filter { Settings.enabledProviders.contains($0) }.map { id in
            ProviderView(id: id, displayName: id.displayName, error: store.visibleError(id),
                         accounts: AppCoordinator.accountViews(id, store: store, ledger: ledger))
        }
        let vm = TrayViewModel(providers: providers, customLimitCents: Settings.customLimitCents)
        do {
            FileHandle.standardOutput.write(try encode(build(from: vm, includeInactiveAccounts: includeInactiveAccounts)))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("failed to encode report: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func dollars(_ cents: Double) -> Double { (cents).rounded() / 100 }
    private static func rounded(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
