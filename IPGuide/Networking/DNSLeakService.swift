import Darwin
import Foundation

/// Determines the recursive DNS resolver your traffic is actually using and
/// compares it to the current egress country.
///
/// Technique:
/// 1. `getaddrinfo("whoami.akamai.net")` — Akamai runs a response-your-IP
///    DNS beacon: when your system resolver queries this name, Akamai
///    returns an A record whose VALUE is your resolver's public IP.
///    This is a DNS-level operation; HTTPS connectivity to Akamai is not
///    required.
/// 2. `GET https://ip.guide/{resolver_ip}` — same JSON shape as the main
///    lookup, giving us country + ASN.
/// 3. Compare resolver country vs egress country. A mismatch means your
///    DNS queries are exiting via a different network than your HTTPS
///    traffic — i.e. a DNS leak.
actor DNSLeakService {
    private let session: URLSession
    private let beaconHost: String
    private var status: DNSLeakStatus = .unknown
    private var continuations: [UUID: AsyncStream<DNSLeakStatus>.Continuation] = [:]
    private var inflight: Task<Void, Never>?

    init(beaconHost: String = "whoami.akamai.net") {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": IPGuideProvider.userAgent]
        self.session = URLSession(configuration: config)
        self.beaconHost = beaconHost
    }

    nonisolated func stream() -> AsyncStream<DNSLeakStatus> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    func snapshot() -> DNSLeakStatus { status }

    func check(against egress: IPDataModel) async {
        if inflight != nil { return }
        let task = Task<Void, Never> { [weak self] in
            await self?.performCheck(against: egress)
        }
        inflight = task
        await task.value
        inflight = nil
    }

    func reset() {
        status = .unknown
        emit()
    }

    // MARK: Implementation

    private func performCheck(against egress: IPDataModel) async {
        let resolverIP: String
        do {
            resolverIP = try await resolveBeacon()
        } catch {
            Log.network.debug(
                "DNS leak: resolver lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            status = .failed(reason: String(localized: "Couldn't resolve DNS beacon"), at: Date())
            emit()
            return
        }

        // Try to enrich with geo/ASN via ip.guide. If enrichment fails,
        // fall back to IP-equality heuristic so we still report something.
        if let resolverModel = try? await fetchIPInfo(for: resolverIP) {
            let info = DNSInfo(
                resolverIP: resolverIP,
                resolverCountryCode: resolverModel.countryAlpha2,
                resolverCountryName: resolverModel.location.country,
                resolverASN: resolverModel.network.autonomousSystem.asn,
                resolverASNName: resolverModel.network.autonomousSystem.name
                    .components(separatedBy: " - ").first,
                egressIP: egress.ip,
                egressCountryCode: egress.countryAlpha2,
                egressCountryName: egress.location.country,
                checkedAt: Date()
            )
            status = info.matchesEgress ? .matches(info) : .mismatch(info)
        } else {
            let info = DNSInfo(
                resolverIP: resolverIP,
                resolverCountryCode: nil,
                resolverCountryName: nil,
                resolverASN: nil,
                resolverASNName: nil,
                egressIP: egress.ip,
                egressCountryCode: egress.countryAlpha2,
                egressCountryName: egress.location.country,
                checkedAt: Date()
            )
            status = info.matchesEgress ? .matches(info) : .mismatch(info)
        }
        emit()
    }

    /// Resolve `beaconHost` through the system resolver and return the
    /// first A-record value as a dotted-decimal string.
    private func resolveBeacon() async throws -> String {
        let host = beaconHost
        return try await Task.detached(priority: .utility) {
            try Self.resolveAName(host)
        }.value
    }

    /// Synchronous `getaddrinfo`-based A lookup. Called from a detached
    /// Task so it doesn't block the actor.
    private static func resolveAName(_ host: String) throws -> String {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,         // IPv4 only; beacon is v4
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let err = getaddrinfo(host, nil, &hints, &result)
        guard err == 0, let result else {
            throw NSError(
                domain: "DNSLeakService",
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "getaddrinfo failed (\(err))"]
            )
        }
        defer { freeaddrinfo(result) }

        let addr = result.pointee.ai_addr
        let addrLen = result.pointee.ai_addrlen
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ni = getnameinfo(
            addr, addrLen,
            &buffer, socklen_t(buffer.count),
            nil, 0,
            NI_NUMERICHOST
        )
        guard ni == 0 else {
            throw NSError(
                domain: "DNSLeakService",
                code: Int(ni),
                userInfo: [NSLocalizedDescriptionKey: "getnameinfo failed (\(ni))"]
            )
        }
        return String(cString: buffer)
    }

    private func fetchIPInfo(for ip: String) async throws -> IPDataModel {
        guard let url = URL(string: "https://ip.guide/\(ip)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(IPDataModel.self, from: data)
    }

    private func register(id: UUID, continuation: AsyncStream<DNSLeakStatus>.Continuation) {
        continuations[id] = continuation
        continuation.yield(status)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit() {
        for c in continuations.values { c.yield(status) }
    }
}
