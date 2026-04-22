import Foundation

actor IPService {
    private let provider: IPProvider
    private let cache: IPCache
    private let minimumGap: TimeInterval = 5

    private var inflight: Task<IPDataModel, Error>?
    private var lastSuccessAt: Date?
    private var currentState: IPState
    private var continuations: [UUID: AsyncStream<IPState>.Continuation] = [:]

    init(provider: IPProvider, cache: IPCache) {
        self.provider = provider
        self.cache = cache
        if let cached = cache.load() {
            self.currentState = .loaded(cached.model, fetchedAt: cached.fetchedAt)
        } else {
            self.currentState = .idle
        }
    }

    nonisolated func stateStream() -> AsyncStream<IPState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(id: UUID, continuation: AsyncStream<IPState>.Continuation) {
        continuations[id] = continuation
        continuation.yield(currentState)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func currentSnapshot() -> IPState { currentState }

    @discardableResult
    func refresh(force: Bool = false) async -> IPState {
        if let last = lastSuccessAt, !force, Date().timeIntervalSince(last) < minimumGap {
            return currentState
        }

        if let existing = inflight {
            _ = try? await existing.value
            return currentState
        }

        emit(.loading(cached: currentState.model))

        // Single attempt. Previously this retried up to 3× with exponential
        // backoff, which made a failure sequence hammer an unreachable host
        // for ~45 s — noisy when the user is on a China egress that can't
        // see ip.guide. If the first try fails, we just drop into `.error`
        // and wait for the next scheduler/network-event trigger.
        let task = Task<IPDataModel, Error> { [provider] in
            try await provider.fetch()
        }
        inflight = task

        defer { inflight = nil }

        do {
            let model = try await task.value
            let fetchedAt = Date()
            cache.save(.init(model: model, fetchedAt: fetchedAt))
            lastSuccessAt = fetchedAt
            emit(.loaded(model, fetchedAt: fetchedAt))
        } catch {
            let err = IPServiceError.from(error)
            let cached = cache.load()
            emit(.error(err, cached: cached?.model, fetchedAt: cached?.fetchedAt))
        }

        return currentState
    }

    private func emit(_ state: IPState) {
        currentState = state
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}
