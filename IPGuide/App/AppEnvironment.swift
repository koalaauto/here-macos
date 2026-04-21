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
    let dnsLeakService: DNSLeakService
    let throughputService: ThroughputService
    let scheduler: RefreshScheduler
    let latencyScheduler: LatencyScheduler
    let launchAtLogin: LaunchAtLoginService

    /// Background task that feeds new IP observations into the history +
    /// DNS-leak services. Retained so we can cancel on shutdown.
    @MainActor private var stateObserverTask: Task<Void, Never>?

    @MainActor
    init() {
        let cache = IPCache()
        let settings = SettingsStore()
        let networkMonitor = NetworkMonitor()
        let sleepWakeObserver = SleepWakeObserver()
        let regionMapper = RegionMapper()
        let ipService = IPService(provider: IPGuideProvider(), cache: cache)
        let latencyService = LatencyService(
            capacity: settings.latencySlotCount,
            target: settings.latencyProbeTarget.url
        )
        let historyService = IPHistoryService()
        let dnsLeakService = DNSLeakService()
        let throughputService = ThroughputService()
        let scheduler = RefreshScheduler(
            ipService: ipService,
            settings: settings,
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

        self.cache = cache
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.sleepWakeObserver = sleepWakeObserver
        self.regionMapper = regionMapper
        self.ipService = ipService
        self.latencyService = latencyService
        self.historyService = historyService
        self.dnsLeakService = dnsLeakService
        self.throughputService = throughputService
        self.scheduler = scheduler
        self.latencyScheduler = latencyScheduler
        self.launchAtLogin = launchAtLogin
    }

    @MainActor
    func start() {
        networkMonitor.start()
        sleepWakeObserver.start()
        scheduler.start()
        latencyScheduler.start()
        startStateObservation()
        Task { await ipService.refresh() }
    }

    @MainActor
    func shutdown() {
        stateObserverTask?.cancel()
        stateObserverTask = nil
        scheduler.stop()
        latencyScheduler.stop()
        sleepWakeObserver.stop()
        networkMonitor.stop()
    }

    /// Fan IPService state changes out to the history + DNS-leak services.
    /// Keeps both features passive — no separate schedulers needed because
    /// they react to IP refreshes that the main RefreshScheduler already
    /// drives.
    @MainActor
    private func startStateObservation() {
        stateObserverTask?.cancel()
        let history = historyService
        let dns = dnsLeakService
        let stream = ipService.stateStream()
        stateObserverTask = Task {
            var lastIP: String?
            for await state in stream {
                guard let model = state.model else { continue }
                // Only trigger on actual IP change (or first observation).
                // The state stream fires on every loading/loaded transition;
                // we de-dup here so we don't hammer the DNS beacon on each
                // scheduled refresh.
                if lastIP == model.ip { continue }
                lastIP = model.ip
                await history.record(model)
                await dns.check(against: model)
            }
        }
    }
}
