import Foundation

actor LatencyService {
    /// Lazily-built session. We `invalidateAndCancel` it on
    /// network-plane changes (`rebuildSession()`) so keep-alive
    /// connections from the previous proxy state can't ride into
    /// the new state — same defensive pattern as `IPWhoIsProvider`'s
    /// per-fetch session creation, just at a coarser granularity
    /// here because per-probe rebuild would be wasteful for
    /// 5 s tick latency probing.
    private var session: URLSession
    private var samples: [LatencySample] = []
    private var capacity: Int
    private var currentTarget: URL?
    private var continuations: [UUID: AsyncStream<[LatencySample]>.Continuation] = [:]
    private var inflight: Task<Void, Never>?

    init(capacity: Int = 30, target: URL? = LatencyProbeTarget.googleGenerate.presetURL) {
        self.session = Self.makeSession()
        self.capacity = max(1, capacity)
        self.currentTarget = target
    }

    /// Tear down and re-create the URLSession. Call after a network-
    /// plane change (interface switch / proxy toggle / reachability
    /// recovery) so the next probe lands on a fresh connection that
    /// reflects the current routing.
    func rebuildSession() {
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    /// `.default` (not `.ephemeral`) — inherits the user's system
    /// proxy so the probe times the *perceived* path, same one the
    /// popover IP comes from. `.ephemeral` would silently bypass
    /// the proxy and report direct-link latency, contradicting
    /// what the user sees in the IP card.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent": AppUserAgent.value
        ]
        return URLSession(configuration: config)
    }

    nonisolated func stream() -> AsyncStream<[LatencySample]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    func snapshot() -> [LatencySample] { samples }

    func setCapacity(_ n: Int) {
        let clamped = max(1, n)
        capacity = clamped
        if samples.count > clamped {
            samples = Array(samples.suffix(clamped))
            emit()
        }
    }

    func setTarget(_ url: URL?) {
        if currentTarget != url {
            currentTarget = url
        }
    }

    func reset() {
        samples.removeAll()
        emit()
    }

    func probe() async {
        if inflight != nil { return }
        let task = Task<Void, Never> { [weak self] in
            await self?.performProbe()
        }
        inflight = task
        await task.value
        inflight = nil
    }

    private func performProbe() async {
        // No target = `.custom` selected with an empty/invalid URL.
        // Tick the chain with a "skipped" marker so the user can see
        // the loop is still alive (gray) — distinct from a real
        // timeout (red).
        guard let target = currentTarget else {
            append(LatencySample(latencyMs: nil, wasSkipped: true))
            return
        }
        var request = URLRequest(url: target)
        request.httpMethod = "HEAD"
        let start = Date()
        do {
            // `safeData(for:)` not `data(for:)`: the system API can throw an
            // Obj-C `NSException` from `taskForClassInfo:` that Swift's
            // `catch` cannot see, killing the app with SIGABRT. Fixed in
            // v0.32.1 — see `URLSession+Safe.swift`.
            _ = try await session.safeData(for: request)
            let elapsed = Date().timeIntervalSince(start) * 1000
            append(LatencySample(latencyMs: elapsed))
        } catch {
            append(LatencySample(latencyMs: nil))
        }
    }

    private func append(_ sample: LatencySample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        emit()
    }

    private func register(id: UUID, continuation: AsyncStream<[LatencySample]>.Continuation) {
        continuations[id] = continuation
        continuation.yield(samples)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit() {
        for c in continuations.values { c.yield(samples) }
    }
}
