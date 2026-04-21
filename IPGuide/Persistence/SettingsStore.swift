import Foundation

@Observable
@MainActor
final class SettingsStore {
    var showMode: ShowMode {
        didSet { UserDefaults.standard.set(showMode.rawValue, forKey: Keys.showMode) }
    }

    var countryStyle: CountryStyle {
        didSet { UserDefaults.standard.set(countryStyle.rawValue, forKey: Keys.countryStyle) }
    }

    var refreshIntervalSeconds: Int {
        didSet { UserDefaults.standard.set(refreshIntervalSeconds, forKey: Keys.intervalSeconds) }
    }

    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    var widgetBordered: Bool {
        didSet { UserDefaults.standard.set(widgetBordered, forKey: Keys.widgetBordered) }
    }

    var latencyEnabled: Bool {
        didSet { UserDefaults.standard.set(latencyEnabled, forKey: Keys.latencyEnabled) }
    }

    var latencyProbeTarget: LatencyProbeTarget {
        didSet { UserDefaults.standard.set(latencyProbeTarget.rawValue, forKey: Keys.latencyProbeTarget) }
    }

    var latencyIntervalSeconds: Int {
        didSet { UserDefaults.standard.set(latencyIntervalSeconds, forKey: Keys.latencyIntervalSeconds) }
    }

    var latencySlotCount: Int {
        didSet { UserDefaults.standard.set(latencySlotCount, forKey: Keys.latencySlotCount) }
    }

    var popoverModuleOrder: [PopoverModule] {
        didSet {
            let raw = popoverModuleOrder.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: Keys.popoverModuleOrder)
        }
    }

    /// When off (the default), Throughput hits Cloudflare's speed endpoint.
    /// Escape hatch for networks where `speed.cloudflare.com` is blocked
    /// (SNI filtering, geographic reachability issues, overzealous proxy
    /// rules, …).
    var throughputUseCustomEndpoint: Bool {
        didSet { UserDefaults.standard.set(throughputUseCustomEndpoint, forKey: Keys.throughputUseCustomEndpoint) }
    }

    /// Base URL of a Cloudflare-speedtest-compatible server. Must support
    /// `GET <base>/__down?bytes=N` and `POST <base>/__up`. Only read when
    /// `throughputUseCustomEndpoint` is true; otherwise ignored.
    var throughputCustomEndpoint: String {
        didSet { UserDefaults.standard.set(throughputCustomEndpoint, forKey: Keys.throughputCustomEndpoint) }
    }

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: refreshIntervalSeconds) ?? .m5 }
        set { refreshIntervalSeconds = newValue.rawValue }
    }

    var latencyInterval: LatencyInterval {
        get { LatencyInterval(rawValue: latencyIntervalSeconds) ?? .s60 }
        set { latencyIntervalSeconds = newValue.rawValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.showMode = (defaults.string(forKey: Keys.showMode).flatMap(ShowMode.init(rawValue:))) ?? .both
        self.countryStyle = (defaults.string(forKey: Keys.countryStyle).flatMap(CountryStyle.init(rawValue:))) ?? .flag
        // Migration: coerce retired options (e.g. 30 s) onto a current case.
        let stored = defaults.integer(forKey: Keys.intervalSeconds)
        let validRefreshInterval = RefreshInterval(rawValue: stored) ?? .m5
        self.refreshIntervalSeconds = validRefreshInterval.rawValue
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.widgetBordered = defaults.object(forKey: Keys.widgetBordered) as? Bool ?? true

        self.latencyEnabled = defaults.object(forKey: Keys.latencyEnabled) as? Bool ?? true
        self.latencyProbeTarget = (defaults.string(forKey: Keys.latencyProbeTarget)
            .flatMap(LatencyProbeTarget.init(rawValue:))) ?? .cloudflare
        // Migration: if the stored seconds doesn't map to a current
        // LatencyInterval case (e.g. an older install that saved 10s/30s/120s
        // which have since been retired), fall through to the new default
        // rather than stashing an invalid value.
        let latencyStored = defaults.integer(forKey: Keys.latencyIntervalSeconds)
        let validLatencyInterval = LatencyInterval(rawValue: latencyStored) ?? .s60
        self.latencyIntervalSeconds = validLatencyInterval.rawValue
        // Slot count is a free-form int but the UI only offers a fixed set;
        // coerce unknown values back to the default.
        let slot = defaults.integer(forKey: Keys.latencySlotCount)
        let allowedSlots: Set<Int> = [30, 45, 60]
        self.latencySlotCount = allowedSlots.contains(slot) ? slot : 30

        let savedOrder = (defaults.stringArray(forKey: Keys.popoverModuleOrder) ?? [])
            .compactMap(PopoverModule.init(rawValue:))
        self.popoverModuleOrder = Self.mergeWithDefaults(savedOrder)

        self.throughputUseCustomEndpoint = defaults.bool(forKey: Keys.throughputUseCustomEndpoint)
        self.throughputCustomEndpoint = defaults.string(forKey: Keys.throughputCustomEndpoint) ?? ""

        // `didSet` doesn't fire during init, so any values we coerced above
        // still sit in UserDefaults in their pre-migration form and would
        // migrate again on every launch. Write the canonical values back
        // explicitly so the next launch reads them as already-valid.
        defaults.set(validRefreshInterval.rawValue, forKey: Keys.intervalSeconds)
        defaults.set(validLatencyInterval.rawValue, forKey: Keys.latencyIntervalSeconds)
        defaults.set(self.latencySlotCount, forKey: Keys.latencySlotCount)
    }

    private static func mergeWithDefaults(_ saved: [PopoverModule]) -> [PopoverModule] {
        var seen = Set<PopoverModule>()
        var merged: [PopoverModule] = []
        for module in saved where !seen.contains(module) {
            merged.append(module)
            seen.insert(module)
        }
        for module in PopoverModule.defaultOrder where !seen.contains(module) {
            merged.append(module)
        }
        return merged
    }

    private enum Keys {
        static let showMode = "displayStyle.show"
        static let countryStyle = "displayStyle.country"
        static let intervalSeconds = "refresh.intervalSeconds"
        static let launchAtLogin = "launchAtLogin"
        static let widgetBordered = "widget.bordered"
        static let latencyEnabled = "latency.enabled"
        static let latencyProbeTarget = "latency.target"
        static let latencyIntervalSeconds = "latency.intervalSeconds"
        static let latencySlotCount = "latency.slotCount"
        static let popoverModuleOrder = "popover.moduleOrder"
        static let throughputUseCustomEndpoint = "throughput.useCustomEndpoint"
        static let throughputCustomEndpoint = "throughput.customEndpoint"
    }
}
