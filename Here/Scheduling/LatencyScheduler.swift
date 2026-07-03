import Foundation

@MainActor
final class LatencyScheduler {
    private let service: LatencyService
    private let settings: SettingsStore
    private let networkMonitor: NetworkMonitor
    private let sleepWakeObserver: SleepWakeObserver

    private var loopTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?

    init(
        service: LatencyService,
        settings: SettingsStore,
        networkMonitor: NetworkMonitor,
        sleepWakeObserver: SleepWakeObserver
    ) {
        self.service = service
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.sleepWakeObserver = sleepWakeObserver
    }

    func start() {
        syncFromSettings()
        restartLoop()
        observeNetworkEvents()
        observeWakeEvents()
        observeSettingsChanges()
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        networkTask?.cancel(); networkTask = nil
        wakeTask?.cancel(); wakeTask = nil
        settingsTask?.cancel(); settingsTask = nil
    }

    private func syncFromSettings() {
        let capacity = settings.latencySlotCount
        let target = settings.latencyTargetURL
        Task { [service] in
            await service.setCapacity(capacity)
            await service.setTarget(target)
        }
    }

    private func restartLoop() {
        loopTask?.cancel()
        guard settings.latencyEnabled else { return }
        let interval = settings.latencyInterval.seconds
        Log.scheduler.info("Latency loop restarting with interval \(interval, privacy: .public)s")
        loopTask = Task { [weak self] in
            // Fire an initial probe so the user sees data immediately.
            await self?.tickIfOnline()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
                await self?.tickIfOnline()
            }
        }
    }

    private func tickIfOnline() async {
        if case .offline = networkMonitor.reachability { return }
        await service.probe()
    }

    private func observeNetworkEvents() {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            guard let stream = self?.networkMonitor.events() else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case .becameReachable, .interfaceChanged, .pathChanged:
                    // Respect the master switch: with the latency module
                    // off, the periodic loop is already suppressed
                    // (`restartLoop` guards on `latencyEnabled`), so a
                    // network event shouldn't sneak a probe in either —
                    // that would push samples the user can't see and
                    // leave stale data waiting when they re-enable.
                    guard self.settings.latencyEnabled else { break }
                    // Tear down the long-lived URLSession before the
                    // next probe so any keep-alive connections from
                    // the *previous* network plane / proxy state get
                    // discarded. Otherwise the first probe after a
                    // proxy toggle silently rides a stale connection
                    // and reports the wrong path's latency.
                    await service.rebuildSession()
                    try? await Task.sleep(for: .seconds(1))
                    await service.probe()
                case .becameUnreachable:
                    break
                }
            }
        }
    }

    private func observeWakeEvents() {
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            guard let stream = self?.sleepWakeObserver.events() else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case .didWake:
                    try? await Task.sleep(for: .seconds(1))
                    self.restartLoop()
                case .willSleep:
                    loopTask?.cancel()
                }
            }
        }
    }

    private func observeSettingsChanges() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            guard let self else { return }
            var last = snapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                let current = snapshot()
                if current != last {
                    let needsLoopRestart = current.enabled != last.enabled ||
                        current.intervalSeconds != last.intervalSeconds
                    last = current
                    syncFromSettings()
                    if needsLoopRestart { restartLoop() }
                }
            }
        }
    }

    private struct SettingsSnapshot: Equatable {
        let enabled: Bool
        let intervalSeconds: Int
        let slotCount: Int
        let target: URL?
    }

    private func snapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            enabled: settings.latencyEnabled,
            intervalSeconds: settings.latencyInterval.rawValue,
            slotCount: settings.latencySlotCount,
            target: settings.latencyTargetURL
        )
    }
}
