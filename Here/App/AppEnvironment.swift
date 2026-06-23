import Foundation

@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let cache: IPCache
    let networkMonitor: NetworkMonitor
    let sleepWakeObserver: SleepWakeObserver
    let ipService: IPService
    let regionMapper: RegionMapper
    let latencyService: LatencyService
    let historyService: IPHistoryService
    let throughputService: ThroughputService
    let scheduler: RefreshScheduler
    let latencyScheduler: LatencyScheduler
    let launchAtLogin: LaunchAtLoginService
    let updateCoordinator: UpdateCoordinator

    /// SwiftUI's `\.openSettings` action, captured at launch by
    /// `AppDelegate.bootstrapOpenSettingsAction()`. Calling this opens
    /// the SwiftUI `Settings { … }` scene reliably from any context —
    /// the fallback was `NSApp.sendAction(showSettingsWindow:)` which
    /// is unreliable in LSUIElement apps.
    @MainActor var openSettingsAction: (@MainActor () -> Void)?

    /// Background task that feeds new IP observations into the history
    /// service. Retained so we can cancel on shutdown.
    @MainActor private var stateObserverTask: Task<Void, Never>?

    @MainActor
    init() {
        let cache = IPCache()
        let settings = SettingsStore()
        let networkMonitor = NetworkMonitor()
        let sleepWakeObserver = SleepWakeObserver()
        let regionMapper = RegionMapper()
        // Two-provider failover chain (v0.33.0+). Primary is ipwho.is —
        // historically reliable and accurate for VPN egress IPs. Fallback
        // is ip.guide on independent infrastructure so a proxy / VPN
        // rule that breaks one CDN doesn't silently freeze the widget.
        // See IPGuideProvider.swift's header for why ip.guide is back
        // after being removed in v0.26.0, and FallbackChainProvider.swift
        // for why the chain is sequential rather than racing.
        let provider = FallbackChainProvider([
            IPWhoIsProvider(),
            IPGuideProvider()
        ])
        let ipService = IPService(provider: provider, cache: cache)
        let latencyService = LatencyService(
            capacity: settings.latencySlotCount,
            target: settings.latencyTargetURL
        )
        let historyService = IPHistoryService()
        let throughputService = ThroughputService()
        let scheduler = RefreshScheduler(
            ipService: ipService,
            networkMonitor: networkMonitor,
            sleepWakeObserver: sleepWakeObserver
        )
        let latencyScheduler = LatencyScheduler(
            service: latencyService,
            settings: settings,
            networkMonitor: networkMonitor,
            sleepWakeObserver: sleepWakeObserver
        )
        let launchAtLogin = LaunchAtLoginService()
        let updateCoordinator = UpdateCoordinator(
            checker: UpdateChecker(),
            installer: UpdateInstaller(),
            settings: settings
        )

        self.cache = cache
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.sleepWakeObserver = sleepWakeObserver
        self.regionMapper = regionMapper
        self.ipService = ipService
        self.latencyService = latencyService
        self.historyService = historyService
        self.throughputService = throughputService
        self.scheduler = scheduler
        self.latencyScheduler = latencyScheduler
        self.launchAtLogin = launchAtLogin
        self.updateCoordinator = updateCoordinator
    }

    @MainActor
    func start() {
        networkMonitor.start()
        sleepWakeObserver.start()
        scheduler.start()
        latencyScheduler.start()
        updateCoordinator.start()
        startStateObservation()
        // Cold-start refresh: silent so the popover doesn't blur its
        // cached snapshot on first opens; if there's no cache the UI
        // shows its `.idle` placeholder anyway, also silently.
        Task { await ipService.refresh(silent: true) }
    }

    @MainActor
    func shutdown() {
        stateObserverTask?.cancel()
        stateObserverTask = nil
        scheduler.stop()
        latencyScheduler.stop()
        updateCoordinator.stop()
        sleepWakeObserver.stop()
        networkMonitor.stop()
    }

    /// Fan IPService state changes out to the history service. Keeps the
    /// feature passive — no separate scheduler needed because it reacts to
    /// IP refreshes that the main RefreshScheduler already drives.
    @MainActor
    private func startStateObservation() {
        stateObserverTask?.cancel()
        let history = historyService
        let stream = ipService.stateStream()
        stateObserverTask = Task {
            var lastIP: String?
            for await state in stream {
                guard let model = state.model else { continue }
                // Dedup per-IP: the state stream fires on every
                // loading/loaded transition; we only care about actual
                // egress changes.
                if lastIP == model.ip { continue }
                lastIP = model.ip
                await history.record(model)
            }
        }
    }
}
