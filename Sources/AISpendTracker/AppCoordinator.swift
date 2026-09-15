import AppKit

/// Top-level wiring: owns the menu bar and one independent poller per enabled
/// provider. Each provider has its own poller, on-disk history, and runtime state;
/// a failure in one only updates that provider's error and never disturbs the
/// others. The tray shows each provider's last fetch as a fixed snapshot, so it
/// repaints only when new data/errors arrive — no periodic redraw timer.
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let store = UsageStore()   // per-provider persisted last-fetch time + data
    private let rawStore = RawResponseStore()   // per-provider last raw response (for copy)
    private let spendLedger = SpendLedger()   // reconstructs spend onto the local calendar month

    /// Set to `true` to develop the UI against fake data with no network/Keychain.
    private static let useMockData = false

    /// Everything we keep per running provider.
    private struct Runtime {
        let provider: UsageProvider
        let poller: UsagePoller
        let history: UsageHistory
        var snapshot: ProviderSnapshot?
        var lastUpdated: Date?
        var error: String?
        var lastRawResponse: String?
        var reconstructedSpend: SpendLedger.Entry?
    }
    private var runtimes: [ProviderID: Runtime] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("AI Spend Tracker launching (mock=\(Self.useMockData), enabled=\(Settings.enabledProviders.map(\.rawValue).sorted()))")
        LaunchAtLogin.enableByDefaultOnce()

        menuBar.launchAtLoginState = { LaunchAtLogin.isEnabled }
        menuBar.onToggleLaunchAtLogin = { LaunchAtLogin.toggle() }
        menuBar.onRestart = { Relauncher.restartAfterTermination() }
        menuBar.onRefresh = { [weak self] in self?.runtimes.values.forEach { $0.poller.fetchNow() } }
        menuBar.onSetProvider = { [weak self] id, enabled in self?.setProvider(id, enabled: enabled) }

        for id in ProviderID.allCases where Settings.enabledProviders.contains(id) {
            startProvider(id)
        }
        render()

        // If the menu bar had no room for our icon, let the user know (once per launch)
        // and point them at a menu-bar organizer, so it doesn't look like a silent crash.
        menuBar.warnIfNotDisplayed()
    }

    // MARK: - Provider lifecycle

    private func makeProvider(_ id: ProviderID) -> UsageProvider {
        if Self.useMockData { return MockProvider(id: id) }
        switch id {
        case .claude: return ClaudeUsageFetcher()
        case .codex:  return CodexUsageFetcher()
        case .cursor: return CursorUsageFetcher()
        case .devin:  return DevinUsageFetcher()
        }
    }

    private func startProvider(_ id: ProviderID) {
        guard runtimes[id] == nil else { return }
        let provider = makeProvider(id)
        let poller = UsagePoller(provider: provider, lastAttemptAt: store.lastFetchAt(id))
        // Restore the exact last-known display state, so a restart within the cooldown
        // isn't blank — and doesn't misrepresent the provider — while we wait to
        // re-fetch. `lastUpdated` is the last *success* (data freshness), never the last
        // attempt. A failed fetch is only surfaced after six consecutive failures, so
        // short-lived outages keep their last known reading, even across a restart.
        // Show the persisted reconstruction on launch; do NOT re-ingest the cached
        // snapshot (it was already folded into the ledger when first fetched — replaying
        // it would double-count). A month rollover that happened while we were closed is
        // corrected by the first fresh fetch's `ingest`.
        runtimes[id] = Runtime(provider: provider, poller: poller,
                               history: UsageHistory(providerID: id),
                               snapshot: store.snapshot(id), lastUpdated: store.lastSuccessAt(id),
                               error: store.visibleError(id),
                               lastRawResponse: rawStore.raw(id),
                               reconstructedSpend: spendLedger.entry(id))

        poller.onAttempt = { [weak self] at in self?.store.recordAttempt(id, at: at) }
        poller.onData = { [weak self] snapshot, raw in
            guard let self else { return }
            let at = Date()
            self.store.saveSnapshot(id, snapshot, at: at)
            self.rawStore.record(id, raw: raw, at: at)
            self.runtimes[id]?.snapshot = snapshot
            self.runtimes[id]?.lastUpdated = at
            self.runtimes[id]?.error = nil
            self.runtimes[id]?.lastRawResponse = raw
            self.runtimes[id]?.history.record(snapshot)
            // Fold this fresh reading into the calendar-month reconstruction (once per
            // new sample, in order). Providers with no spend contribute nothing.
            if let spend = snapshot.spend {
                self.runtimes[id]?.reconstructedSpend = self.spendLedger.ingest(id, spend: spend, now: at)
            }
            self.render()
        }
        poller.onError = { [weak self] message, raw in
            guard let self else { return }
            let count = self.store.saveError(id, message)
            self.runtimes[id]?.error = count >= UsageStore.visibleErrorThreshold ? message : nil
            // Persist the failing body when the response carried one, so "copy last
            // response" surfaces the actual error payload rather than stale success.
            if let raw {
                self.rawStore.record(id, raw: raw, at: Date())
                self.runtimes[id]?.lastRawResponse = raw
            }
            self.render()
        }
        poller.start()
    }

    private func stopProvider(_ id: ProviderID) {
        runtimes[id]?.poller.stop()
        runtimes[id] = nil
    }

    /// Toggle a provider on/off from the Providers submenu: persist the choice, start
    /// or stop its poller, and repaint.
    private func setProvider(_ id: ProviderID, enabled: Bool) {
        var set = Settings.enabledProviders
        if enabled { set.insert(id) } else { set.remove(id) }
        Settings.enabledProviders = set
        if enabled { startProvider(id) } else { stopProvider(id) }
        Log.log("provider \(id.rawValue) \(enabled ? "enabled" : "disabled")")
        render()
    }

    // MARK: - Render

    /// Assemble the ordered view model (providers in canonical order) and hand it to
    /// the menu bar.
    private func render() {
        let providers = ProviderID.allCases.compactMap { id -> ProviderView? in
            guard let rt = runtimes[id] else { return nil }
            return ProviderView(id: id, displayName: rt.provider.displayName,
                                snapshot: rt.snapshot, lastUpdated: rt.lastUpdated,
                                error: rt.error, history: rt.history.recent(),
                                lastRawResponse: rt.lastRawResponse,
                                reconstructedSpend: rt.reconstructedSpend)
        }
        menuBar.apply(TrayViewModel(providers: providers, customLimitCents: Settings.customLimitCents,
                                    spendDisplayMode: Settings.spendDisplayMode,
                                    trayStyle: Settings.trayStyle))
    }
}
