import Foundation

actor LatencyService {
    private let session: URLSession
    private var samples: [LatencySample] = []
    private var capacity: Int
    private var currentTarget: URL
    private var continuations: [UUID: AsyncStream<[LatencySample]>.Continuation] = [:]
    private var inflight: Task<Void, Never>?

    init(capacity: Int = 30, target: URL = LatencyProbeTarget.cloudflare.url) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent": IPGuideProvider.userAgent
        ]
        self.session = URLSession(configuration: config)
        self.capacity = max(1, capacity)
        self.currentTarget = target
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

    func setTarget(_ url: URL) {
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
        var request = URLRequest(url: currentTarget)
        request.httpMethod = "HEAD"
        let start = Date()
        do {
            _ = try await session.data(for: request)
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
