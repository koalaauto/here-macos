import Foundation

/// Default IP-lookup provider since v0.26 (replacing ip.guide).
///
/// Why ipwho.is:
/// - HTTPS-native, no API key required, ~1 req/s per client IP.
///   Ships well in a free menu-bar app — no shared-quota risk
///   across the user base, no token to embed.
/// - Returns ISO `country_code` directly, so flag resolution is
///   authoritative. The previous default (ip.guide) returned an
///   English country name which we had to look up via Apple's
///   `Locale` tables — that round-trip silently failed for
///   spelling drift like "Republic of Korea" vs "South Korea".
/// - Better accuracy than ip.guide on VPN / proxy egress IPs.
///   The trigger case for the migration: a Korean VPN exit
///   (AS209847 WorkTitans B.V.) that ip.guide reported as
///   "Cyprus / null"; ipwho.is, ip-api.com, and ipinfo.io all
///   correctly report South Korea / Seoul.
///
/// Wire-format quirks worth knowing:
/// - On invalid input, rate-limit, or upstream malfunction, ipwho.is
///   returns HTTP 200 with `{"success": false, "message": "..."}`
///   instead of an HTTP error code. We treat this as a transport
///   failure and surface the upstream message.
/// - `city` can come back as JSON `null`, `""`, or a real string.
///   We normalise empty strings to `nil` so consumers only need to
///   handle one "missing" form.
struct IPWhoIsProvider: IPProvider {
    let name = "ipwho.is"
    private let endpoint: URL
    /// Builds a URLSession per fetch. Default factory uses
    /// `Self.makeSession()`; tests inject a mock factory wired to
    /// `URLProtocolMock` to drive the integration paths
    /// (200 + valid JSON, 200 + success:false, HTTP error,
    /// network error) without real network.
    private let sessionFactory: @Sendable () -> URLSession

    init(
        endpoint: URL = URL(string: "https://ipwho.is/")!,
        sessionFactory: @escaping @Sendable () -> URLSession = IPWhoIsProvider.makeSession
    ) {
        self.endpoint = endpoint
        self.sessionFactory = sessionFactory
    }

    static func makeSession() -> URLSession {
        // `URLSessionConfiguration.default` (not `.ephemeral`) so the
        // session inherits the user's system proxy settings — when
        // someone enables Clash / Surge / WireGuard in "set system
        // proxy" mode, the lookup goes through the proxy just like
        // every other app in their browser session, and we report
        // the *post-proxy* egress (which is what the user expects to
        // see).
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": AppUserAgent.value
        ]
        return URLSession(configuration: config)
    }

    func fetch() async throws -> IPDataModel {
        // Build a brand-new URLSession every fetch and tear it down
        // when we're done. Two reasons we don't reuse one:
        //
        // 1. URLSessionConfiguration.default snapshots the system
        //    proxy at session-creation time. When the user rapidly
        //    toggles a proxy app's "system proxy" switch, URLSession's
        //    connection pool can hold keep-alive connections that
        //    were established before the toggle — a fresh request
        //    silently rides one of those, surfacing as "popover still
        //    shows my old egress after switching proxies".
        // 2. A long-lived session may also cache DNS resolutions
        //    in its lower layers, which compounds (1).
        //
        // Cost: one TCP + TLS handshake per fetch (~100–300 ms).
        // Negligible — fetch frequency is at most one-per-network-
        // event or once-a-minute on the loop.
        let session = sessionFactory()
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"

        let (data, response): (Data, URLResponse)
        do {
            // `safeData(for:)` — NSException barrier, see v0.32.1
            // (URLSession+Safe.swift). The system `data(for:)` can
            // SIGABRT from `taskForClassInfo:` on certain proxy/utun
            // states; `safeData` converts that to a Swift error.
            (data, response) = try await session.safeData(for: request)
        } catch {
            throw IPServiceError.from(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw IPServiceError.transport(message: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IPServiceError.http(statusCode: http.statusCode)
        }

        let raw: IPWhoIsRawResponse
        do {
            raw = try JSONDecoder().decode(IPWhoIsRawResponse.self, from: data)
        } catch {
            throw IPServiceError.decoding(message: error.localizedDescription)
        }

        // ipwho.is signals "we couldn't process this" via a body
        // flag, not an HTTP status. Surface the upstream `message`
        // when present so the popover error banner is informative
        // ("Invalid IP address" / "rate limited" / etc.) rather than
        // generic.
        if raw.success == false {
            throw IPServiceError.transport(
                message: raw.message ?? "ipwho.is reported an error"
            )
        }

        return Self.map(raw)
    }

    // MARK: - Mapping (provider raw → app domain)

    /// Pure transform from the wire shape into our internal model.
    /// Exposed at module scope so tests can exercise it directly
    /// against fixtures without standing up a real URLSession.
    static func map(_ raw: IPWhoIsRawResponse) -> IPDataModel {
        let normalisedCity = raw.city.flatMap { $0.isEmpty ? nil : $0 }

        let asn = IPDataModel.Network.AutonomousSystem(
            asn: raw.connection.asn,
            // ipwho.is doesn't split short-handle and legal name —
            // `org` is the closest thing to both. `asnLabel` is
            // tolerant: if `name` lacks a " - " separator, the whole
            // string passes through unchanged.
            name: raw.connection.org,
            organization: raw.connection.org,
            // ipwho.is doesn't expose ASN registration country / RIR.
            country: nil,
            rir: nil
        )

        let network = IPDataModel.Network(
            // Likewise no CIDR.
            cidr: nil,
            autonomousSystem: asn
        )

        let location = IPDataModel.Location(
            city: normalisedCity,
            country: raw.country,
            timezone: raw.timezone.id,
            latitude: raw.latitude,
            longitude: raw.longitude
        )

        return IPDataModel(
            ip: raw.ip,
            countryAlpha2: raw.countryCode.uppercased(),
            network: network,
            location: location
        )
    }
}

// MARK: - Wire format (private to the provider)

/// Mirrors the JSON returned by `GET https://ipwho.is/` (and
/// `https://ipwho.is/<ip>`). Only the fields the app consumes are
/// declared; ipwho.is sends a few extras (continent, postal,
/// calling_code, capital, borders, flag image URL, …) that we ignore.
struct IPWhoIsRawResponse: Decodable, Equatable, Sendable {
    let ip: String
    /// Present only when ipwho.is wants to flag an error condition
    /// (success=false). Treated as `true` when missing.
    let success: Bool?
    let message: String?
    let country: String
    let countryCode: String
    let city: String?
    let latitude: Double
    let longitude: Double
    let connection: Connection
    let timezone: Timezone

    enum CodingKeys: String, CodingKey {
        case ip
        case success
        case message
        case country
        case countryCode = "country_code"
        case city
        case latitude
        case longitude
        case connection
        case timezone
    }

    struct Connection: Decodable, Equatable, Sendable {
        let asn: Int
        let org: String
    }

    struct Timezone: Decodable, Equatable, Sendable {
        let id: String
    }
}
