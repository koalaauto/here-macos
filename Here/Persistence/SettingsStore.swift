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

    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    var latencyEnabled: Bool {
        didSet { UserDefaults.standard.set(latencyEnabled, forKey: Keys.latencyEnabled) }
    }

    var latencyProbeTarget: LatencyProbeTarget {
        didSet { UserDefaults.standard.set(latencyProbeTarget.rawValue, forKey: Keys.latencyProbeTarget) }
    }

    /// HTTPS URL probed when `latencyProbeTarget == .custom`. Ignored
    /// otherwise. Any reachable resource works — the probe issues a
    /// HEAD and times the round trip.
    var latencyCustomURL: String {
        didSet { UserDefaults.standard.set(latencyCustomURL, forKey: Keys.latencyCustomURL) }
    }

    /// Concrete URL the latency probe should hit. Returns `nil` when
    /// `.custom` is selected with an empty/invalid URL — the scheduler
    /// then skips probing rather than recording timeouts against a
    /// bogus host.
    var latencyTargetURL: URL? {
        latencyProbeTarget.resolveURL(customURL: latencyCustomURL)
    }

    var latencyIntervalSeconds: Int {
        didSet { UserDefaults.standard.set(latencyIntervalSeconds, forKey: Keys.latencyIntervalSeconds) }
    }

    var latencySlotCount: Int {
        didSet { UserDefaults.standard.set(latencySlotCount, forKey: Keys.latencySlotCount) }
    }

    /// When true, the status-bar pill border turns red whenever the
    /// most recent latency probe is in the "poor" bucket (timeout or
    /// >2000 ms). When false, the border is always neutral regardless
    /// of latency. Only meaningful when the latency module itself is
    /// enabled.
    var widgetLatencyAlert: Bool {
        didSet { UserDefaults.standard.set(widgetLatencyAlert, forKey: Keys.widgetLatencyAlert) }
    }

    var popoverModuleOrder: [PopoverModule] {
        didSet {
            let raw = popoverModuleOrder.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: Keys.popoverModuleOrder)
        }
    }

    /// Which download source the Throughput card hits. Cachefly is default
    /// (wide global footprint, rarely filtered); users on networks that
    /// prefer Cloudflare or need a self-hosted server can switch here.
    var throughputEndpoint: ThroughputEndpoint {
        didSet { UserDefaults.standard.set(throughputEndpoint.rawValue, forKey: Keys.throughputEndpoint) }
    }

    /// HTTP(S) URL of the file used when `throughputEndpoint == .custom`.
    /// Ignored otherwise. Any resource that responds 200 OK to a GET and
    /// delivers ≥ a few MB of body works.
    var throughputCustomURL: String {
        didSet { UserDefaults.standard.set(throughputCustomURL, forKey: Keys.throughputCustomURL) }
    }

    /// How often to poll GitHub for a newer release.
    /// Defaults to `.daily` — see `UpdateCheckFrequency` for the
    /// rationale on the available cadences.
    var updateCheckFrequency: UpdateCheckFrequency {
        didSet { UserDefaults.standard.set(updateCheckFrequency.rawValue, forKey: Keys.updateCheckFrequency) }
    }

    /// Wall-clock time of the last successful (or attempted-and-failed)
    /// GitHub release check. The scheduler uses this to enforce the
    /// `updateCheckFrequency` interval. Updated by `UpdateCoordinator`,
    /// not directly by the picker.
    var lastUpdateCheckAt: Date? {
        didSet {
            if let date = lastUpdateCheckAt {
                UserDefaults.standard.set(date, forKey: Keys.lastUpdateCheckAt)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastUpdateCheckAt)
            }
        }
    }

    /// Version the user explicitly chose to skip (clicked "Skip this
    /// version" in the update-available alert). When non-nil and equal
    /// to the latest GitHub tag, the auto-check stays silent. Manual
    /// "Check now" still surfaces the alert — the skip is a soft
    /// suppression, not a permanent block.
    var skippedUpdateVersion: String? {
        didSet {
            if let version = skippedUpdateVersion {
                UserDefaults.standard.set(version, forKey: Keys.skippedUpdateVersion)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.skippedUpdateVersion)
            }
        }
    }

    /// Concrete URL the throughput run should hit. `nil` only when
    /// `.custom` is selected with an empty/invalid URL — in that case
    /// the Run Test handler surfaces a failure rather than substituting
    /// a preset.
    var throughputTargetURL: URL? {
        throughputEndpoint.resolveURL(customURL: throughputCustomURL)
    }

    var latencyInterval: LatencyInterval {
        get { LatencyInterval(rawValue: latencyIntervalSeconds) ?? .s60 }
        set { latencyIntervalSeconds = newValue.rawValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.showMode = (defaults.string(forKey: Keys.showMode).flatMap(ShowMode.init(rawValue:))) ?? .both
        self.countryStyle = (defaults.string(forKey: Keys.countryStyle).flatMap(CountryStyle.init(rawValue:))) ?? .flag
        // (Retired v0.29.0): refresh-interval picker. The IP refresh
        // cadence is now hardcoded at 5 s in `RefreshScheduler`. Any
        // legacy `refresh.intervalSeconds` value sitting in
        // UserDefaults is ignored. We don't actively wipe it — it's
        // a small int and harmless dormant data.
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)

        self.latencyEnabled = defaults.object(forKey: Keys.latencyEnabled) as? Bool ?? true
        self.latencyProbeTarget = (defaults.string(forKey: Keys.latencyProbeTarget)
            .flatMap(LatencyProbeTarget.init(rawValue:))) ?? .googleGenerate
        self.latencyCustomURL = defaults.string(forKey: Keys.latencyCustomURL) ?? ""
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

        self.widgetLatencyAlert = defaults.object(forKey: Keys.widgetLatencyAlert) as? Bool ?? true

        let savedOrder = (defaults.stringArray(forKey: Keys.popoverModuleOrder) ?? [])
            .compactMap(PopoverModule.init(rawValue:))
        self.popoverModuleOrder = Self.mergeWithDefaults(savedOrder)

        // Throughput endpoint + custom URL, with migration from the
        // v0.20.0 `throughputUseCustomEndpoint` + `throughputCustomEndpoint`
        // pair. If the new key is set, use it directly. Otherwise, if the
        // legacy toggle was on, map to `.custom` carrying the legacy URL;
        // else fall through to the default `.cachefly`.
        let legacyUseCustom = defaults.bool(forKey: Keys.legacyThroughputUseCustomEndpoint)
        let legacyCustomURL = defaults.string(forKey: Keys.legacyThroughputCustomEndpoint) ?? ""

        if let raw = defaults.string(forKey: Keys.throughputEndpoint),
           let endpoint = ThroughputEndpoint(rawValue: raw) {
            self.throughputEndpoint = endpoint
        } else if legacyUseCustom, !legacyCustomURL.isEmpty {
            self.throughputEndpoint = .custom
        } else {
            self.throughputEndpoint = .cachefly
        }

        if let stored = defaults.string(forKey: Keys.throughputCustomURL) {
            self.throughputCustomURL = stored
        } else {
            self.throughputCustomURL = legacyCustomURL
        }

        // Update-check settings. Default cadence is daily — see
        // UpdateCheckFrequency for the trade-off; users on the
        // unsigned-build path can drop to `.never` if they prefer to
        // upgrade manually.
        self.updateCheckFrequency = (defaults.string(forKey: Keys.updateCheckFrequency)
            .flatMap(UpdateCheckFrequency.init(rawValue:))) ?? .daily
        self.lastUpdateCheckAt = defaults.object(forKey: Keys.lastUpdateCheckAt) as? Date
        self.skippedUpdateVersion = defaults.string(forKey: Keys.skippedUpdateVersion)

        // `didSet` doesn't fire during init, so any values we coerced above
        // still sit in UserDefaults in their pre-migration form and would
        // migrate again on every launch. Write the canonical values back
        // explicitly so the next launch reads them as already-valid.
        defaults.set(validLatencyInterval.rawValue, forKey: Keys.latencyIntervalSeconds)
        defaults.set(self.latencySlotCount, forKey: Keys.latencySlotCount)
        defaults.set(self.latencyProbeTarget.rawValue, forKey: Keys.latencyProbeTarget)
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
        static let launchAtLogin = "launchAtLogin"
        // (Retired): `refresh.intervalSeconds` (v0.29.0 — hardcoded 5 s),
        // `refresh.onNetworkChange` (v0.28.0 — short polling subsumed it).
        // Old keys left dormant in UserDefaults; harmless, not worth a
        // migration to wipe.
        static let latencyEnabled = "latency.enabled"
        static let latencyProbeTarget = "latency.target"
        static let latencyCustomURL = "latency.customURL"
        static let latencyIntervalSeconds = "latency.intervalSeconds"
        static let latencySlotCount = "latency.slotCount"
        static let widgetLatencyAlert = "widget.latencyAlert"
        static let popoverModuleOrder = "popover.moduleOrder"
        static let throughputEndpoint = "throughput.endpoint"
        static let throughputCustomURL = "throughput.customURL"
        // Legacy v0.20.0 keys — read once on launch for migration, never written.
        static let legacyThroughputUseCustomEndpoint = "throughput.useCustomEndpoint"
        static let legacyThroughputCustomEndpoint = "throughput.customEndpoint"
        static let updateCheckFrequency = "update.frequency"
        static let lastUpdateCheckAt = "update.lastCheckedAt"
        static let skippedUpdateVersion = "update.skippedVersion"
    }
}
