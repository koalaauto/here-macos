import Foundation
import Testing

@testable import Here

/// Test-only `IPProvider` that runs a caller-supplied closure on each
/// `fetch()` call. Closure runs on whatever Task is calling `fetch()`,
/// so an actor-backed call log can record the call order
/// deterministically.
private struct StubIPProvider: IPProvider {
    let name: String
    private let work: @Sendable () async throws -> IPDataModel

    init(name: String, work: @escaping @Sendable () async throws -> IPDataModel) {
        self.name = name
        self.work = work
    }

    func fetch() async throws -> IPDataModel {
        try await work()
    }
}

/// Order-of-calls log shared between stub providers in a single test.
/// Each stub appends its name on entry; the test asserts the resulting
/// sequence. Actor so concurrent appends are safe even though the
/// chain is sequential — keeps the helper general.
private actor CallLog {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

private func sampleModel(ip: String = "1.2.3.4", country: String = "US") -> IPDataModel {
    IPDataModel(
        ip: ip,
        countryAlpha2: country,
        network: .init(
            cidr: nil,
            autonomousSystem: .init(
                asn: 12345, name: "Stub", organization: "Stub",
                country: nil, rir: nil
            )
        ),
        location: .init(
            city: nil, country: country,
            timezone: "UTC",
            latitude: 0, longitude: 0
        )
    )
}

@Suite("FallbackChainProvider")
struct FallbackChainProviderTests {

    /// Display name is "primary → fallback → …" so the value can be
    /// logged or surfaced in diagnostics. Verifies the formatter
    /// doesn't accidentally drop or reorder providers.
    @Test func nameJoinsProviderNamesWithArrow() {
        let chain = FallbackChainProvider([
            StubIPProvider(name: "primary") { sampleModel() },
            StubIPProvider(name: "fallback") { sampleModel() }
        ])
        #expect(chain.name == "primary → fallback")
    }

    /// Healthy primary path: chain returns the primary's result and
    /// never touches the fallback. This is the steady-state behaviour
    /// — costs us one extra `try`/`catch` frame on every poll, that's
    /// it.
    @Test func firstProviderSuccessReturnsItsResult() async throws {
        let log = CallLog()
        let chain = FallbackChainProvider([
            StubIPProvider(name: "primary") {
                await log.record("primary")
                return sampleModel(ip: "1.1.1.1", country: "US")
            },
            StubIPProvider(name: "fallback") {
                await log.record("fallback")
                return sampleModel(ip: "9.9.9.9", country: "CA")
            }
        ])

        let model = try await chain.fetch()
        #expect(model.ip == "1.1.1.1")
        #expect(model.countryAlpha2 == "US")
        let names = await log.names
        #expect(names == ["primary"])
    }

    /// The actual bug fix: primary throws, fallback succeeds, user
    /// gets the fallback's answer. Without this, the v0.32.x build
    /// just showed "??" and a stale timestamp when a VPN broke
    /// ipwho.is's CDN — the v0.33.0 motivation.
    @Test func fallbackUsedWhenPrimaryThrows() async throws {
        let log = CallLog()
        let chain = FallbackChainProvider([
            StubIPProvider(name: "primary") {
                await log.record("primary")
                throw IPServiceError.http(statusCode: 503)
            },
            StubIPProvider(name: "fallback") {
                await log.record("fallback")
                return sampleModel(ip: "9.9.9.9", country: "CA")
            }
        ])

        let model = try await chain.fetch()
        #expect(model.ip == "9.9.9.9")
        #expect(model.countryAlpha2 == "CA")
        let names = await log.names
        #expect(names == ["primary", "fallback"])
    }

    /// Every link in the chain fails. Per the design comment in
    /// `FallbackChainProvider.swift`, we re-throw the **primary's**
    /// error (not the last fallback's) so the user-visible diagnostic
    /// stays anchored to the canonical provider. Verifies that
    /// contract end-to-end.
    @Test func allFailedThrowsPrimaryError() async throws {
        let chain = FallbackChainProvider([
            StubIPProvider(name: "primary") {
                throw IPServiceError.transport(message: "primary blew up")
            },
            StubIPProvider(name: "fallback") {
                throw IPServiceError.transport(message: "fallback also blew up")
            }
        ])

        do {
            _ = try await chain.fetch()
            Issue.record("Expected throw when all providers fail")
        } catch let error as IPServiceError {
            if case .transport(let message) = error {
                #expect(message == "primary blew up")
            } else {
                Issue.record("Expected .transport, got \(error)")
            }
        }
    }

    /// Three-provider chain where the primary and the first fallback
    /// both fail and the second fallback succeeds. Verifies the chain
    /// keeps walking past the first failure and doesn't short-circuit
    /// on the second.
    @Test func walksPastMultipleFailuresUntilSuccess() async throws {
        let log = CallLog()
        let chain = FallbackChainProvider([
            StubIPProvider(name: "a") {
                await log.record("a")
                throw IPServiceError.timeout
            },
            StubIPProvider(name: "b") {
                await log.record("b")
                throw IPServiceError.http(statusCode: 500)
            },
            StubIPProvider(name: "c") {
                await log.record("c")
                return sampleModel(ip: "3.3.3.3", country: "JP")
            }
        ])

        let model = try await chain.fetch()
        #expect(model.countryAlpha2 == "JP")
        let names = await log.names
        #expect(names == ["a", "b", "c"])
    }

    /// External task cancellation between attempts unwinds the chain
    /// promptly, throwing CancellationError rather than continuing
    /// to attempt fallback providers. Lets `IPService.withHardTimeout`
    /// reliably bound the chain's wall-clock cost.
    @Test func cancellationBetweenAttemptsPropagates() async throws {
        let log = CallLog()
        let chain = FallbackChainProvider([
            StubIPProvider(name: "primary") {
                await log.record("primary")
                throw IPServiceError.http(statusCode: 503)
            },
            StubIPProvider(name: "fallback") {
                await log.record("fallback")
                return sampleModel()
            }
        ])

        let task = Task<Void, Error> {
            // Cancel ourselves before fetch even starts. The first
            // checkCancellation() at the top of the loop fires.
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await chain.fetch()
        }

        do {
            try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // OK
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let names = await log.names
        #expect(names.isEmpty)
    }
}
