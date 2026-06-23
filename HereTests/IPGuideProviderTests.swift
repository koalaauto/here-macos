import Foundation
import Testing

@testable import Here

private final class IPGuideTestBundleAnchor {}

/// Suite-private URLProtocol — see `UpdateMockURLProtocol` in
/// `UpdateCheckerTests.swift` for the cross-suite race rationale.
/// Each provider's suite gets its own subclass so Swift Testing's
/// parallel-suite execution doesn't have two tests collide on a
/// shared class-static handler slot.
final class IPGuideMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?
    private static let lock = NSLock()

    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        self.handler = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IPGuideMockURLProtocol.self]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        IPGuideMockURLProtocol.lock.lock()
        let h = IPGuideMockURLProtocol.handler
        IPGuideMockURLProtocol.lock.unlock()
        guard let h else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try h(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("IPGuideProvider", .serialized)
struct IPGuideProviderTests {

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: IPGuideTestBundleAnchor.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Fixture \(name).json not found in test bundle"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Mapping

    /// Happy-path mapping for the real `https://ip.guide/` response
    /// that motivated re-adding this provider (the US-via-AT&T egress
    /// the user observed during the v0.33.0 provider evaluation).
    /// Validates that CIDR / RIR / ASN-country make it into the model
    /// (ipwho.is omits them; one reason ip.guide is the richer
    /// fallback) and that the country reverse-lookup hits the
    /// Apple-Locale path for the easy case ("United States").
    @Test func mapsUnitedStatesResponseEndToEnd() throws {
        let data = try loadFixture("ipguide_us_response")
        let raw = try JSONDecoder().decode(IPGuideRawResponse.self, from: data)
        let model = try IPGuideProvider.map(raw)

        #expect(model.ip == "23.132.124.147")
        #expect(model.countryAlpha2 == "US")
        #expect(model.location.country == "United States")
        #expect(model.location.city == "Los Angeles")
        #expect(model.location.timezone == "America/Los_Angeles")
        #expect(abs(model.location.latitude - 34.0614) < 0.0001)
        #expect(abs(model.location.longitude - (-118.3072)) < 0.0001)

        #expect(model.network.cidr == "23.132.124.0/24")
        #expect(model.network.autonomousSystem.asn == 7018)
        #expect(model.network.autonomousSystem.organization == "AT&T Enterprises, LLC")
        #expect(model.network.autonomousSystem.country == "US")
        #expect(model.network.autonomousSystem.rir == "ARIN")

        // The "<HANDLE> - <legal name>" pattern that triggers
        // `asnLabel`'s handle-stripping branch, exactly the case
        // ip.guide historically shipped.
        #expect(model.asnLabel == "AS7018 · ATT-INTERNET4")
    }

    /// **The reason the drift dict exists.** ip.guide historically
    /// shipped `"Republic of Korea"` where Apple Locale knows the
    /// country as `"South Korea"`. The Locale-only reverse-lookup
    /// misses it; the drift dict catches it and resolves to `KR`.
    /// Without this path, every Korean VPN egress would surface as
    /// `IPServiceError.decoding` and the chain would just throw —
    /// the bug that made us remove ip.guide in v0.26.0. This test is
    /// the guarantee that the bug stays fixed.
    @Test func resolvesAlpha2ForLongFormCountryNameViaDriftDict() throws {
        let data = try loadFixture("ipguide_kr_response")
        let raw = try JSONDecoder().decode(IPGuideRawResponse.self, from: data)
        let model = try IPGuideProvider.map(raw)

        #expect(model.countryAlpha2 == "KR")
        #expect(model.location.country == "Republic of Korea")
        #expect(model.location.city == "Seoul")
        // ASN's RIR country is NL (Worktitans B.V. is Dutch-registered)
        // — confirms we don't use the ASN country for the flag. The
        // egress flag is KR per `location.country` only.
        #expect(model.network.autonomousSystem.country == "NL")
        #expect(model.network.autonomousSystem.rir == "RIPE NCC")
    }

    // MARK: - alpha2(forCountryName:)

    /// Apple Locale path: common, exact-spelling country names should
    /// resolve cheaply without hitting the drift dict. Sampling a
    /// handful across continents.
    @Test func resolvesCommonCountryNamesViaLocale() {
        #expect(IPGuideProvider.alpha2(forCountryName: "United States") == "US")
        #expect(IPGuideProvider.alpha2(forCountryName: "Japan") == "JP")
        #expect(IPGuideProvider.alpha2(forCountryName: "Hong Kong") == "HK")
        #expect(IPGuideProvider.alpha2(forCountryName: "Germany") == "DE")
        #expect(IPGuideProvider.alpha2(forCountryName: "Brazil") == "BR")
    }

    /// Case insensitivity and whitespace tolerance — defensive,
    /// because we don't fully trust what an upstream might do under
    /// edge conditions.
    @Test func isCaseAndWhitespaceInsensitive() {
        #expect(IPGuideProvider.alpha2(forCountryName: "  united states ") == "US")
        #expect(IPGuideProvider.alpha2(forCountryName: "JAPAN") == "JP")
    }

    /// ISO 3166 long forms that Apple Locale short-forms. The drift
    /// dict's whole job. Test a handful spanning Asia / Europe /
    /// Americas so a regression in any one row trips the suite.
    @Test func resolvesIsoLongFormsViaDriftDict() {
        #expect(IPGuideProvider.alpha2(forCountryName: "Republic of Korea") == "KR")
        #expect(IPGuideProvider.alpha2(forCountryName: "Korea, Republic of") == "KR")
        #expect(IPGuideProvider.alpha2(forCountryName: "Russian Federation") == "RU")
        #expect(IPGuideProvider.alpha2(forCountryName: "Iran, Islamic Republic of") == "IR")
        #expect(IPGuideProvider.alpha2(forCountryName: "Czech Republic") == "CZ")
        #expect(IPGuideProvider.alpha2(forCountryName: "Viet Nam") == "VN")
        #expect(IPGuideProvider.alpha2(forCountryName: "Taiwan, Province of China") == "TW")
        #expect(IPGuideProvider.alpha2(forCountryName: "United States of America") == "US")
    }

    /// Truly-unknown name → nil → caller throws `.decoding`. Confirms
    /// we don't silently emit a flagless model on bad upstream data.
    @Test func returnsNilForUnknownCountryName() {
        #expect(IPGuideProvider.alpha2(forCountryName: "Wakanda") == nil)
        #expect(IPGuideProvider.alpha2(forCountryName: "") == nil)
    }

    /// Unknown country name path → `.decoding` via `map(_:)`. The
    /// chain's contract is that an unresolvable country fails the
    /// whole fetch rather than emits a half-broken model.
    @Test func mapThrowsDecodingForUnresolvableCountry() {
        let raw = IPGuideRawResponse(
            ip: "1.2.3.4",
            network: .init(cidr: nil, autonomousSystem: .init(
                asn: 0, name: "n", organization: "n", country: nil, rir: nil
            )),
            location: .init(
                city: nil, country: "Wakanda",
                timezone: "UTC", latitude: 0, longitude: 0
            )
        )

        do {
            _ = try IPGuideProvider.map(raw)
            Issue.record("Expected .decoding for unknown country name")
        } catch let error as IPServiceError {
            if case .decoding = error {
                // OK
            } else {
                Issue.record("Expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("Expected IPServiceError, got \(error)")
        }
    }

    // MARK: - End-to-end via URLProtocol

    private func mockedProvider() -> IPGuideProvider {
        IPGuideProvider(
            endpoint: URL(string: "https://mock.ip.guide/")!,
            sessionFactory: { IPGuideMockURLProtocol.session() }
        )
    }

    private func httpResponse(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://mock.ip.guide/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Happy path through the URLSession stack — confirms decode + map
    /// + Locale lookup all wire together cleanly.
    @Test func fetchSucceedsOnValidResponse() async throws {
        let data = try loadFixture("ipguide_us_response")
        IPGuideMockURLProtocol.install { _ in (self.httpResponse(200), data) }
        defer { IPGuideMockURLProtocol.clear() }

        let model = try await mockedProvider().fetch()
        #expect(model.ip == "23.132.124.147")
        #expect(model.countryAlpha2 == "US")
    }

    /// HTTP error → `.http(statusCode:)`. In the fallback chain, this
    /// is the signal that triggers… nothing further, because ip.guide
    /// is currently the LAST link. But the contract still matters for
    /// the popover banner.
    @Test func fetchSurfacesHTTPError() async throws {
        IPGuideMockURLProtocol.install { _ in (self.httpResponse(503), Data()) }
        defer { IPGuideMockURLProtocol.clear() }

        do {
            _ = try await mockedProvider().fetch()
            Issue.record("Expected throw on 503")
        } catch let error as IPServiceError {
            if case .http(let code) = error {
                #expect(code == 503)
            } else {
                Issue.record("Expected .http(503), got \(error)")
            }
        }
    }

    /// Garbage body → `.decoding`.
    @Test func fetchSurfacesDecodingFailure() async throws {
        IPGuideMockURLProtocol.install { _ in
            (self.httpResponse(200), Data("<!DOCTYPE html>not json".utf8))
        }
        defer { IPGuideMockURLProtocol.clear() }

        do {
            _ = try await mockedProvider().fetch()
            Issue.record("Expected throw on garbage body")
        } catch let error as IPServiceError {
            if case .decoding = error {
                // OK
            } else {
                Issue.record("Expected .decoding, got \(error)")
            }
        }
    }
}
