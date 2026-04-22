import Foundation
import Testing

@testable import Here

@Suite("IPService")
struct IPServiceTests {
    private func samplePayload() -> Data {
        let json = """
        {
          "ip": "1.2.3.4",
          "network": {
            "cidr": "1.2.3.0/24",
            "hosts": { "start": "1.2.3.1", "end": "1.2.3.254" },
            "autonomous_system": {
              "asn": 1, "name": "X", "organization": "X",
              "country": "US", "rir": "ARIN"
            }
          },
          "location": {
            "city": "Here", "country": "US", "timezone": "UTC",
            "latitude": 0, "longitude": 0
          }
        }
        """
        return Data(json.utf8)
    }

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

    private func sampleModel() throws -> IPDataModel {
        try JSONDecoder().decode(IPDataModel.self, from: samplePayload())
    }

    @Test func successEmitsLoadedState() async throws {
        let model = try sampleModel()
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

    @Test func errorStateFallsBackToCache() async throws {
        let cache = ephemeralCache()
        let prev = try sampleModel()
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
