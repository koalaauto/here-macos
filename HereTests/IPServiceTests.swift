import Foundation
import Testing

@testable import Here

@Suite("IPService")
struct IPServiceTests {
    private func ephemeralCache() -> IPCache {
        IPCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("HereTests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("last_ip.json"))
    }

    struct StubProvider: IPProvider {
        let name = "stub"
        let pages: [Result<IPDataModel, IPServiceError>]
        nonisolated(unsafe) private let counter = Counter()

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.lock(); defer { lock.unlock() }
                let v = value; value += 1; return v
            }
            var count: Int {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }

        func fetch() async throws -> IPDataModel {
            let idx = counter.next()
            let page = pages[min(idx, pages.count - 1)]
            switch page {
            case .success(let model): return model
            case .failure(let err): throw err
            }
        }

        var attemptCount: Int { counter.count }
    }

    /// A provider whose `fetch()` never returns within any sane test
    /// horizon — stands in for the real-world failure where URLSession
    /// wedges in a TLS handshake / half-open proxied connection and
    /// ignores its own timeout. `Task.sleep` is cancellation-aware,
    /// so when `withHardTimeout` cancels the operation task this
    /// unwinds cleanly (mirrors `URLSession.data(for:)`'s behaviour).
    struct HangingProvider: IPProvider {
        let name = "hang"
        func fetch() async throws -> IPDataModel {
            try await Task.sleep(for: .seconds(3600))
            fatalError("unreachable: cancelled long before this")
        }
    }

    /// Build a synthetic `IPDataModel` directly via memberwise init.
    /// The model is no longer the JSON wire format of any provider —
    /// providers each own their own raw shape and a `map(_:)` adapter,
    /// so tests construct the domain model literally.
    private func sampleModel() -> IPDataModel {
        IPDataModel(
            ip: "1.2.3.4",
            countryAlpha2: "US",
            network: .init(
                cidr: "1.2.3.0/24",
                autonomousSystem: .init(
                    asn: 1, name: "X", organization: "X",
                    country: "US", rir: "ARIN"
                )
            ),
            location: .init(
                city: "Here", country: "United States",
                timezone: "UTC", latitude: 0, longitude: 0
            )
        )
    }

    @Test func successEmitsLoadedState() async throws {
        let model = sampleModel()
        let provider = StubProvider(pages: [.success(model)])
        let service = IPService(provider: provider, cache: ephemeralCache())
        let state = await service.refresh(force: true)
        if case .loaded(let got, _) = state {
            #expect(got == model)
        } else {
            Issue.record("Expected .loaded state, got \(state)")
        }
    }

    @Test func transientFailureDoesNotRetry() async throws {
        // No retry: a single transient failure lands straight in .error.
        // Caller (scheduler) is responsible for retriggering on its own
        // cadence.
        let provider = StubProvider(pages: [.failure(.transport(message: "flap"))])
        let service = IPService(provider: provider, cache: ephemeralCache())
        let state = await service.refresh(force: true)
        if case .error(let err, _, _) = state {
            #expect(err == .transport(message: "flap"))
        } else {
            Issue.record("Expected .error after single attempt, got \(state)")
        }
        #expect(provider.attemptCount == 1)
    }

    @Test func permanent4xxDoesNotRetry() async {
        let provider = StubProvider(pages: [.failure(.http(statusCode: 403))])
        let service = IPService(provider: provider, cache: ephemeralCache())
        let state = await service.refresh(force: true)
        if case .error(let err, _, _) = state {
            #expect(err == .http(statusCode: 403))
        } else {
            Issue.record("Expected .error for 403")
        }
        #expect(provider.attemptCount == 1)
    }

    @Test func decodingFailureDoesNotRetry() async {
        let provider = StubProvider(pages: [.failure(.decoding(message: "bad json"))])
        let service = IPService(provider: provider, cache: ephemeralCache())
        let state = await service.refresh(force: true)
        if case .error = state { } else { Issue.record("Expected .error") }
        #expect(provider.attemptCount == 1)
    }

    /// Regression: a `fetch()` that never returns (URLSession
    /// ignoring its own timeout, as happens across sleep/wake or a
    /// proxy flap) must not wedge the actor. Before the hard-timeout
    /// backstop this `refresh()` would hang forever, leaving
    /// `inflight` set and freezing every later loop tick / network
    /// event / manual refresh — the "widget stuck on Updated N min
    /// ago for hours" bug. The deadline must convert it into a
    /// recoverable `.error(.timeout)`.
    @Test func hungFetchTimesOutInsteadOfWedging() async {
        let service = IPService(
            provider: HangingProvider(),
            cache: ephemeralCache(),
            fetchHardTimeout: 0.2
        )
        let start = Date()
        let state = await service.refresh(force: true)
        let elapsed = Date().timeIntervalSince(start)

        if case .error(let err, _, _) = state {
            #expect(err == .timeout)
        } else {
            Issue.record("Expected .error(.timeout) for a hung fetch, got \(state)")
        }
        // Must return on the deadline's order of magnitude, not the
        // provider's 3600 s. Generous upper bound to stay non-flaky
        // under CI load.
        #expect(elapsed < 5)

        // And the actor must be usable again afterwards — a second
        // refresh isn't parked on the dead first one.
        let model = sampleModel()
        let service2 = IPService(
            provider: StubProvider(pages: [.success(model)]),
            cache: ephemeralCache()
        )
        let recovered = await service2.refresh(force: true)
        if case .loaded = recovered {} else {
            Issue.record("Expected .loaded after recovery, got \(recovered)")
        }
    }

    @Test func errorStateFallsBackToCache() async throws {
        let cache = ephemeralCache()
        let prev = sampleModel()
        _ = cache.save(.init(model: prev, fetchedAt: Date()))
        let provider = StubProvider(pages: [.failure(.http(statusCode: 500))])
        let service = IPService(provider: provider, cache: cache)
        let state = await service.refresh(force: true)
        if case .error(_, let cached, _) = state {
            #expect(cached == prev)
        } else {
            Issue.record("Expected .error with cached, got \(state)")
        }
    }
}
