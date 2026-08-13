import Foundation

/// Persists each provider's last fetch attempt time, last successful snapshot, and the
/// error from its most recent attempt (if it failed) to disk, so the app survives its
/// own frequent restarts without re-hitting APIs *and* without misrepresenting a
/// known-broken provider as healthy. On launch we reuse this cache and only fetch a
/// provider once its cooldown since the last *attempt* has elapsed. Keyed by
/// `ProviderID` so providers are independent.
@MainActor
final class UsageStore {
    private struct ProviderCache: Codable {
        /// When we last *attempted* a fetch (success or failure) — drives the cooldown
        /// only. Deliberately distinct from `lastSuccessAt`: a failed attempt bumps this
        /// but must not make stale data look freshly updated.
        var lastFetchAt: Date?
        /// When we last *succeeded* — the freshness of `snapshot`, and what the "Updated
        /// … ago" line reflects across restarts.
        var lastSuccessAt: Date?
        var snapshot: ProviderSnapshot?
        /// The user-facing message from the last attempt if it failed, else nil. Kept
        /// with the snapshot so a restart restores the exact last-known display state:
        /// a non-nil error over a retained snapshot is the stale (dimmed + ⚠︎) reading.
        var lastError: String?
    }
    private struct Cache: Codable {
        var providers: [String: ProviderCache]
    }

    private var cache = Cache(providers: [:])
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppPaths.applicationSupport.appendingPathComponent("usage-cache.json")
        }
        guard let raw = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode(Cache.self, from: raw) else { return }
        cache = decoded
    }

    func lastFetchAt(_ id: ProviderID) -> Date? { cache.providers[id.rawValue]?.lastFetchAt }
    func lastSuccessAt(_ id: ProviderID) -> Date? { cache.providers[id.rawValue]?.lastSuccessAt }
    func snapshot(_ id: ProviderID) -> ProviderSnapshot? { cache.providers[id.rawValue]?.snapshot }
    func lastError(_ id: ProviderID) -> String? { cache.providers[id.rawValue]?.lastError }

    /// Record that we hit `id`'s API at `date` (success or failure) — the cooldown is
    /// measured from this.
    func recordAttempt(_ id: ProviderID, at date: Date) {
        cache.providers[id.rawValue, default: ProviderCache()].lastFetchAt = date
        save()
    }

    /// Record fresh data from a successful fetch of `id` at `date`. Stamps the success
    /// time (freshness) and clears any persisted error, since a success means the
    /// provider is no longer in a failed state — keeping the invariant that `lastError`
    /// is non-nil iff the last attempt failed.
    func saveSnapshot(_ id: ProviderID, _ snapshot: ProviderSnapshot, at date: Date) {
        cache.providers[id.rawValue, default: ProviderCache()].snapshot = snapshot
        cache.providers[id.rawValue, default: ProviderCache()].lastSuccessAt = date
        cache.providers[id.rawValue, default: ProviderCache()].lastError = nil
        save()
    }

    /// Record that `id`'s most recent attempt failed with `message`. The retained
    /// snapshot (if any) is left untouched, so the pair reconstructs the stale reading.
    func saveError(_ id: ProviderID, _ message: String) {
        cache.providers[id.rawValue, default: ProviderCache()].lastError = message
        save()
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(cache) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }
}

/// How the combined spend is shown in the menu bar: as the pie ring (default), as a
/// green dollar figure, or not at all. Only governs the tray glyph — the
/// dropdown always keeps the rich spend ring.
enum SpendDisplayMode: String, CaseIterable {
    case circle, text, off
}

/// How the tray draws each window: as a ring (the default — a time wedge under a usage
/// arc) or as a vertical bar (the same two readings unrolled into a column, about half
/// the width). Purely a tray choice; the dropdown header always shows rings.
enum TrayStyle: String, CaseIterable {
    case rings, bars
}

/// App preferences backed by UserDefaults.
enum Settings {
    private static let customLimitKey = "aiut.customCostTotalCents"
    private static let enabledProvidersKey = "aiut.enabledProviders"
    private static let spendDisplayKey = "aiut.spendDisplayMode"
    private static let trayStyleKey = "aiut.trayStyle"

    /// Default combined spend-pie total ($2500). Always set — the spend pie has a
    /// denominator even before the user customizes it.
    static let defaultCustomLimitCents: Double = 250_000

    /// The dollar total (in cents) the combined spend pie fills against. May be 0,
    /// which turns the spend ring into a plain "any spend at all" indicator (empty at
    /// $0, full above) — see `UsageMath.spendFraction`.
    static var customLimitCents: Double {
        get { UserDefaults.standard.object(forKey: customLimitKey) as? Double ?? defaultCustomLimitCents }
        set { UserDefaults.standard.set(newValue, forKey: customLimitKey) }
    }

    /// How the combined spend renders in the menu bar (default: the pie ring).
    static var spendDisplayMode: SpendDisplayMode {
        get { SpendDisplayMode(rawValue: UserDefaults.standard.string(forKey: spendDisplayKey) ?? "") ?? .circle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: spendDisplayKey) }
    }

    /// How each window is drawn in the tray (default: rings).
    static var trayStyle: TrayStyle {
        get { TrayStyle(rawValue: UserDefaults.standard.string(forKey: trayStyleKey) ?? "") ?? .rings }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: trayStyleKey) }
    }

    /// Which providers are shown. On first run — nothing persisted yet — all
    /// providers are enabled. After that the user's explicit choice is honored,
    /// including turning them all off (which persists as an empty selection, kept
    /// distinct from the never-set state by the key's absence).
    static var enabledProviders: Set<ProviderID> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: enabledProvidersKey) as? [String] else {
                return Set(ProviderID.allCases)
            }
            return Set(raw.compactMap(ProviderID.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: enabledProvidersKey)
        }
    }
}
