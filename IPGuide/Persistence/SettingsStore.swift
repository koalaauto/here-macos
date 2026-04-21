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

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: refreshIntervalSeconds) ?? .m5 }
        set { refreshIntervalSeconds = newValue.rawValue }
    }

    var latencyInterval: LatencyInterval {
        get { LatencyInterval(rawValue: latencyIntervalSeconds) ?? .s30 }
        set { latencyIntervalSeconds = newValue.rawValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.showMode = (defaults.string(forKey: Keys.showMode).flatMap(ShowMode.init(rawValue:))) ?? .both
        self.countryStyle = (defaults.string(forKey: Keys.countryStyle).flatMap(CountryStyle.init(rawValue:))) ?? .flag
        let stored = defaults.integer(forKey: Keys.intervalSeconds)
        self.refreshIntervalSeconds = stored > 0 ? stored : RefreshInterval.m5.rawValue
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.widgetBordered = defaults.object(forKey: Keys.widgetBordered) as? Bool ?? true

        self.latencyEnabled = defaults.object(forKey: Keys.latencyEnabled) as? Bool ?? true
        self.latencyProbeTarget = (defaults.string(forKey: Keys.latencyProbeTarget)
            .flatMap(LatencyProbeTarget.init(rawValue:))) ?? .cloudflare
        let latencyStored = defaults.integer(forKey: Keys.latencyIntervalSeconds)
        self.latencyIntervalSeconds = latencyStored > 0 ? latencyStored : LatencyInterval.s30.rawValue
        let slot = defaults.integer(forKey: Keys.latencySlotCount)
        self.latencySlotCount = (15...120).contains(slot) ? slot : 30

        let savedOrder = (defaults.stringArray(forKey: Keys.popoverModuleOrder) ?? [])
            .compactMap(PopoverModule.init(rawValue:))
        self.popoverModuleOrder = Self.mergeWithDefaults(savedOrder)
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
    }
}
