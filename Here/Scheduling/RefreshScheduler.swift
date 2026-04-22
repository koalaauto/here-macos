import Foundation

@MainActor
final class RefreshScheduler {
    private let ipService: IPService
    private let settings: SettingsStore
    private let networkMonitor: NetworkMonitor
    private let sleepWakeObserver: SleepWakeObserver
    private let systemNetworkObserver: SystemNetworkObserver

    private var loopTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var systemNetworkTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?

    /// Last time a network/proxy-driven refresh actually fired, plus the
    /// snapshot it was fired against. Used to collapse bursts — an
    /// interfaceChanged + pathChanged + systemStateChanged trio from a
    /// single network change all land within a few seconds and carry
    /// the same snapshot, so only the first fires.
    private var lastNetworkTriggeredRefresh: Date = .distantPast
    private var lastNetworkTriggeredSnapshot: String = ""

    /// Last time a network-triggered refresh ended in `.error`, plus
    /// the network-plane snapshot it was made against. Suppression is
    /// scoped to that snapshot: if the user switches to a genuinely
    /// different network, the next event fires normally instead of
    /// being coalesced as "retry noise". Manual refresh bypasses this —
    /// it calls `triggerNow()` directly, not through this path.
    private var lastFailedNetworkRefresh: Date = .distantPast
    private var lastFailedSnapshot: String = ""

    /// Minimum gap between two network-triggered refreshes during normal
    /// operation. Narrow — a single network change typically emits
    /// systemStateChanged + interfaceChanged + pathChanged within a few seconds
    /// and we want one refresh per change, not three.
    private static let networkRefreshCoalesceWindow: TimeInterval = 5

    /// After a network-triggered refresh fails, ignore further network
    /// events for this long. Prevents the "I switched networks, it
    /// loaded, failed, and then started loading again by itself" pattern
    /// — the user explicitly doesn't want retries. Long enough to
    /// absorb the tail of a network-settling event storm; short enough
    /// that if the user deliberately switches to a working node after
    /// waiting, the next change still triggers a fresh attempt.
    private static let postErrorCooldown: TimeInterval = 30

    init(
        ipService: IPService,
        settings: SettingsStore,
        networkMonitor: NetworkMonitor,
        sleepWakeObserver: SleepWakeObserver,
        systemNetworkObserver: SystemNetworkObserver
    ) {
        self.ipService = ipService
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.sleepWakeObserver = sleepWakeObserver
        self.systemNetworkObserver = systemNetworkObserver
    }

    func start() {
        restartLoop()
        observeNetworkEvents()
        observeSystemNetworkEvents()
        observeWakeEvents()
        observeSettingsChanges()
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        networkTask?.cancel(); networkTask = nil
        systemNetworkTask?.cancel(); systemNetworkTask = nil
        wakeTask?.cancel(); wakeTask = nil
        settingsTask?.cancel(); settingsTask = nil
    }

    func triggerNow() {
        Task { [ipService] in await ipService.refresh(force: true) }
    }

    private func restartLoop() {
        loopTask?.cancel()
        let interval = settings.refreshInterval.seconds
        Log.scheduler.info("Loop restarting with interval \(interval, privacy: .public)s")
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
                guard let self else { break }
                await self.tickIfOnline()
            }
        }
    }

    private func tickIfOnline() async {
        if case .offline = networkMonitor.reachability {
            Log.scheduler.debug("Skipping tick; offline")
            return
        }
        await ipService.refresh()
    }

    private func observeNetworkEvents() {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            guard let stream = self?.networkMonitor.events() else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case .becameReachable, .interfaceChanged, .pathChanged:
                    guard settings.refreshOnNetworkChange else { continue }
                    await fireNetworkTriggeredRefresh(
                        reason: String(describing: event)
                    )
                case .becameUnreachable:
                    // Airplane mode, link down, fully offline. No point
                    // issuing a fetch URLSession will reject instantly;
                    // just put the state machine in `.error(.offline)`
                    // so the widget stops asserting the cached flag.
                    // Reset our failure snapshot so the next reachable
                    // event (new network plane) isn't locked out by
                    // post-error cooldown.
                    await ipService.forceOffline()
                    lastFailedSnapshot = ""
                    lastFailedNetworkRefresh = .distantPast
                }
            }
        }
    }

    private func observeSystemNetworkEvents() {
        systemNetworkTask?.cancel()
        systemNetworkTask = Task { [weak self] in
            guard let stream = self?.systemNetworkObserver.events() else { return }
            for await _ in stream {
                guard let self else { return }
                guard settings.refreshOnNetworkChange else { continue }
                await fireNetworkTriggeredRefresh(reason: "systemStateChanged")
            }
        }
    }

    /// Coalesce network-triggered refreshes. Both gates are scoped to
    /// the network-plane snapshot (`<interface>:<router>`) — same
    /// snapshot = noise from one settling change, different snapshot =
    /// a genuine re-switch that deserves its own probe.
    ///
    ///  1. Post-error cooldown: once a refresh failed *on a given
    ///     snapshot*, further events carrying the *same* snapshot
    ///     within 30 s are skipped. Switching to a different network
    ///     (different snapshot) fires through immediately.
    ///  2. Burst coalesce: a single network change often emits
    ///     multiple events within a few seconds. Same-snapshot events
    ///     inside a 5 s window are collapsed into the first refresh.
    ///     A different snapshot — e.g. the user switched again while
    ///     we were still loading the previous one — is never
    ///     coalesced, so the new state gets its own probe as soon as
    ///     the in-flight fetch returns.
    private func fireNetworkTriggeredRefresh(reason: String) async {
        let now = Date()
        let snapshot = systemNetworkObserver.primaryIPv4Snapshot()

        let inErrorCooldown = !lastFailedSnapshot.isEmpty
            && lastFailedSnapshot == snapshot
            && now.timeIntervalSince(lastFailedNetworkRefresh) < Self.postErrorCooldown
        if inErrorCooldown {
            Log.scheduler.info(
                "Post-error cooldown (same snapshot) — skipping \(reason, privacy: .public)"
            )
            return
        }
        let inBurst = !lastNetworkTriggeredSnapshot.isEmpty
            && lastNetworkTriggeredSnapshot == snapshot
            && now.timeIntervalSince(lastNetworkTriggeredRefresh)
                < Self.networkRefreshCoalesceWindow
        if inBurst {
            Log.scheduler.debug(
                "Burst coalesce (same snapshot) → skip \(reason, privacy: .public)"
            )
            return
        }
        lastNetworkTriggeredRefresh = now
        lastNetworkTriggeredSnapshot = snapshot
        Log.scheduler.info("Network event → refresh (\(reason, privacy: .public))")

        // Flip the state to `.loading(cached:)` BEFORE the settling wait
        // so the widget + popover reflect "re-checking" as soon as the
        // event arrives — otherwise the UI keeps rendering the prior
        // `.error(.offline)` for 2 s after the network returns, which
        // reads as the app ignoring the change.
        await ipService.beginLoadingPlaceholder()

        // Give URLSession's DNS + connection cache a beat to notice the
        // new network plane before hitting ip.guide.
        try? await Task.sleep(for: .seconds(2))

        let state = await ipService.refresh(force: true)
        if case .error = state {
            lastFailedNetworkRefresh = Date()
            lastFailedSnapshot = snapshot
            Log.scheduler.info(
                "Refresh failed — 30 s cooldown armed for snapshot \(snapshot, privacy: .public)"
            )
        } else {
            lastFailedSnapshot = ""
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
                    try? await Task.sleep(for: .seconds(1.5))
                    self.restartLoop()
                    await ipService.refresh(force: true)
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
            var lastInterval = settings.refreshInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let current = settings.refreshInterval
                if current != lastInterval {
                    lastInterval = current
                    self.restartLoop()
                }
            }
        }
    }
}
