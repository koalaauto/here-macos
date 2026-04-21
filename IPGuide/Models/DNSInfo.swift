import Foundation

/// Snapshot of "what DNS resolver is my traffic actually using?" — compared
/// against the current egress IP to detect DNS leaks.
struct DNSInfo: Codable, Sendable, Equatable {
    /// Public IP of the recursive resolver, as seen by a beacon service
    /// (via `whoami.akamai.net` style lookup).
    let resolverIP: String
    let resolverCountryCode: String?      // uppercase ISO-alpha-2
    let resolverCountryName: String?
    let resolverASN: Int?
    let resolverASNName: String?

    /// The egress IP and country at the time of the check — stored alongside
    /// the resolver info so consumers can render the comparison without
    /// needing the current IP state.
    let egressIP: String
    let egressCountryCode: String
    let egressCountryName: String

    let checkedAt: Date

    /// Heuristic: the DNS and traffic appear to exit via the same country.
    /// Falls back to IP equality when the resolver's country can't be looked
    /// up (network error, rate limit, etc.).
    var matchesEgress: Bool {
        if let resolverCC = resolverCountryCode {
            return resolverCC == egressCountryCode
        }
        return resolverIP == egressIP
    }
}

enum DNSLeakStatus: Sendable, Equatable {
    /// No check performed yet, or reset.
    case unknown
    /// Check complete; resolver and egress align.
    case matches(DNSInfo)
    /// Check complete; resolver and egress appear to exit different networks.
    case mismatch(DNSInfo)
    /// A probe was attempted but failed (e.g. DNS lookup timed out). Kept as
    /// a distinct state so the UI can show "couldn't check" rather than
    /// lying about being fine.
    case failed(reason: String, at: Date)

    var info: DNSInfo? {
        switch self {
        case .matches(let info), .mismatch(let info): info
        case .unknown, .failed:                        nil
        }
    }

    var isLeak: Bool {
        if case .mismatch = self { return true }
        return false
    }
}
