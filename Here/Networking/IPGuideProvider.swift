import Foundation

/// Fallback IP-lookup provider (re-added v0.33.0 after being removed
/// at v0.26.0). Wire endpoint: `GET https://ip.guide/`.
///
/// ## Why ip.guide is back
///
/// We removed ip.guide in v0.26.0 because of a specific bug: it
/// mislabelled some VPN egresses (Korean nodes shown as Cyprus, etc.).
/// During v0.33.0 development we first tried ipinfo.io as the chain's
/// fallback — but field testing on a real user's Clash setup showed
/// ipinfo.io routed differently than [[IPWhoIsProvider]] and reported
/// a Hong Kong egress when their actual proxy was US-based. ip.guide,
/// queried side-by-side on the same setup, returned the correct US
/// AT&T egress.
///
/// **Accuracy beats novelty.** The Korean-as-Cyprus bug is years old
/// and ip.guide's underlying data has likely changed. If it
/// re-surfaces we'll swap to a third provider rather than chain a
/// known-wrong one behind. Bonus: ip.guide ships CIDR + RIR +
/// ASN-country, all of which ipwho.is omits.
///
/// ## Wire-format quirks worth knowing
///
/// - `location.country` is an **English country name** (e.g.
///   `"United States"`), not an ISO alpha-2. We reverse-lookup the
///   alpha-2 via `Locale` — see `alpha2(forCountryName:)` for the
///   drift-tolerance details. This is the same name→code problem that
///   bit us in the ip.guide era; we did NOT have a robust solution
///   then (a static dict that drifted), and we do now (Locale first +
///   small known-drift dict for ISO long forms).
/// - `network.autonomous_system.country` is the ASN's RIR-registered
///   alpha-2 — **NOT** the egress country. Per the CLAUDE.md gotcha,
///   never use it for the flag (VPN ASNs routinely register in a
///   different country than where they actually serve). We surface
///   it as `IPDataModel.Network.AutonomousSystem.country` for the
///   popover's ASN row, but `IPDataModel.countryAlpha2` is *always*
///   derived from `location.country`.
/// - ip.guide returns CIDR (e.g. `"23.132.124.0/24"`) and RIR (e.g.
///   `"ARIN"`) — both of which ipwho.is omits. Free upgrade for the
///   popover when the chain hits the fallback.
/// - On unknown / invalid IPs the upstream returns HTTP 4xx with a
///   minimal error body; we surface it as `IPServiceError.http`.
struct IPGuideProvider: IPProvider {
    let name = "ip.guide"
    private let endpoint: URL
    private let sessionFactory: @Sendable () -> URLSession

    init(
        endpoint: URL = URL(string: "https://ip.guide/")!,
        sessionFactory: @escaping @Sendable () -> URLSession = IPGuideProvider.makeSession
    ) {
        self.endpoint = endpoint
        self.sessionFactory = sessionFactory
    }

    static func makeSession() -> URLSession {
        // Mirrors `IPWhoIsProvider.makeSession`. See that file for the
        // rationale on `.default` (system-proxy aware) over `.ephemeral`,
        // and for per-fetch session lifetime. Keeping both providers
        // identical at this layer so a proxy / connectivity issue
        // affects them as symmetrically as possible.
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
        let session = sessionFactory()
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"

        let (data, response): (Data, URLResponse)
        do {
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

        let raw: IPGuideRawResponse
        do {
            raw = try JSONDecoder().decode(IPGuideRawResponse.self, from: data)
        } catch {
            throw IPServiceError.decoding(message: error.localizedDescription)
        }

        return try Self.map(raw)
    }

    // MARK: - Mapping (provider raw → app domain)

    /// Pure transform from the wire shape into our internal model.
    /// Throws `.decoding` when we can't resolve the country name to an
    /// alpha-2 — better to let the fallback chain move on to the next
    /// provider than to emit a flagless model and silently drop the
    /// most-important field. Tests exercise it directly against fixture
    /// JSON including a deliberate Korean response to cover the drift
    /// path.
    static func map(_ raw: IPGuideRawResponse) throws -> IPDataModel {
        guard let alpha2 = alpha2(forCountryName: raw.location.country) else {
            throw IPServiceError.decoding(
                message: "ip.guide returned an unknown country name: \(raw.location.country)"
            )
        }
        let normalisedCity = raw.location.city.flatMap { $0.isEmpty ? nil : $0 }

        let autonomousSystem = IPDataModel.Network.AutonomousSystem(
            asn: raw.network.autonomousSystem.asn,
            name: raw.network.autonomousSystem.name,
            organization: raw.network.autonomousSystem.organization,
            country: raw.network.autonomousSystem.country?.uppercased(),
            rir: raw.network.autonomousSystem.rir
        )

        let network = IPDataModel.Network(
            cidr: raw.network.cidr,
            autonomousSystem: autonomousSystem
        )

        let location = IPDataModel.Location(
            city: normalisedCity,
            country: raw.location.country,
            timezone: raw.location.timezone,
            latitude: raw.location.latitude,
            longitude: raw.location.longitude
        )

        return IPDataModel(
            ip: raw.ip,
            countryAlpha2: alpha2,
            network: network,
            location: location
        )
    }

    /// English country name → ISO-alpha-2.
    ///
    /// Two-stage lookup. The historical CountryNameMapper (deleted in
    /// v0.26.0) was a static dict that drifted out of date; this is
    /// the principled replacement.
    ///
    /// 1. **Apple Locale reverse-lookup.** Iterate ISO regions Apple
    ///    knows about, compare their `en_US` localized name against
    ///    the provider's name. Catches the common case — `"United
    ///    States"`, `"Hong Kong"`, `"Japan"`, etc. — and gets free
    ///    macOS-version updates when Apple revises a name.
    /// 2. **Drift dict** for ISO 3166 long-form spellings Apple
    ///    short-forms. ip.guide observed historically to ship
    ///    `"Republic of Korea"` where Apple has `"South Korea"`. The
    ///    dict covers the long-form spellings of the ~20 countries
    ///    that have known variance.
    ///
    /// Forced to `en_US` so the comparison is locale-stable — a user
    /// on a Chinese-locale Mac would otherwise get Apple's Chinese
    /// names back and the comparison would never match.
    ///
    /// Returns `nil` if the name resolves to nothing. Caller treats
    /// that as a hard decode error (the chain moves on) rather than
    /// silently emitting a flagless model.
    static func alpha2(forCountryName name: String) -> String? {
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }

        let locale = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions {
            // `Locale.Region.isoRegions` includes subdivisions like
            // `"US-CA"` on some macOS versions. Filter to country-level
            // (2-char) codes only — the drift dict handles the rest.
            let code = region.identifier
            guard code.count == 2 else { continue }
            if let englishName = locale.localizedString(forRegionCode: code),
               englishName.lowercased() == needle {
                return code.uppercased()
            }
        }

        return driftDict[needle]
    }

    /// ISO 3166-1 long-form spellings that Apple's Locale tables ship
    /// in shorter form, so the Locale reverse-lookup misses them.
    /// Keyed lowercased for the case-insensitive match in
    /// `alpha2(forCountryName:)`. Order: alphabetical by alpha-2 to
    /// make additions stable. If a future provider adds a new variant
    /// we hit, add a line; don't try to expand this into a generic
    /// fuzzy-match.
    private static let driftDict: [String: String] = [
        "plurinational state of bolivia": "BO",
        "bolivia, plurinational state of": "BO",
        "czech republic": "CZ",
        "iran, islamic republic of": "IR",
        "islamic republic of iran": "IR",
        "korea, republic of": "KR",
        "republic of korea": "KR",
        "korea (republic of)": "KR",
        "korea, democratic people's republic of": "KP",
        "democratic people's republic of korea": "KP",
        "lao people's democratic republic": "LA",
        "macao": "MO",
        "macau": "MO",
        "republic of moldova": "MD",
        "moldova, republic of": "MD",
        "macedonia, the former yugoslav republic of": "MK",
        "the former yugoslav republic of macedonia": "MK",
        "palestine, state of": "PS",
        "state of palestine": "PS",
        "russian federation": "RU",
        "syrian arab republic": "SY",
        "taiwan, province of china": "TW",
        "united republic of tanzania": "TZ",
        "tanzania, united republic of": "TZ",
        "united states of america": "US",
        "united kingdom of great britain and northern ireland": "GB",
        "bolivarian republic of venezuela": "VE",
        "venezuela, bolivarian republic of": "VE",
        "viet nam": "VN"
    ]
}

// MARK: - Wire format (private to the provider)

/// Mirrors the JSON returned by `GET https://ip.guide/`. Only the
/// fields we consume are declared; the upstream sends extras
/// (`network.hosts.{start, end}`, etc.) that we ignore.
struct IPGuideRawResponse: Decodable, Equatable, Sendable {
    let ip: String
    let network: Network
    let location: Location

    struct Network: Decodable, Equatable, Sendable {
        let cidr: String?
        let autonomousSystem: AutonomousSystem

        enum CodingKeys: String, CodingKey {
            case cidr
            case autonomousSystem = "autonomous_system"
        }

        struct AutonomousSystem: Decodable, Equatable, Sendable {
            let asn: Int
            let name: String
            let organization: String
            /// RIR-registered country (alpha-2). Not the egress country.
            let country: String?
            /// RIR handle, e.g. `"ARIN"`, `"RIPE NCC"`.
            let rir: String?
        }
    }

    struct Location: Decodable, Equatable, Sendable {
        /// City can be null for city-state egresses (HK, SG, MO, …)
        /// just like ipwho.is.
        let city: String?
        /// English country name. Reverse-looked-up to alpha-2 in
        /// `IPGuideProvider.map(_:)`.
        let country: String
        let timezone: String
        let latitude: Double
        let longitude: Double
    }
}
