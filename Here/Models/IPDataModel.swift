import CoreLocation
import Foundation

struct IPDataModel: Codable, Equatable, Sendable {
    let ip: String
    let network: Network
    let location: Location

    struct Network: Codable, Equatable, Sendable {
        let cidr: String
        let hosts: Hosts
        let autonomousSystem: AutonomousSystem

        enum CodingKeys: String, CodingKey {
            case cidr
            case hosts
            case autonomousSystem = "autonomous_system"
        }

        struct Hosts: Codable, Equatable, Sendable {
            let start: String
            let end: String
        }

        struct AutonomousSystem: Codable, Equatable, Sendable {
            let asn: Int
            let name: String
            let organization: String
            let country: String
            let rir: String
        }
    }

    struct Location: Codable, Equatable, Sendable {
        let city: String
        let country: String
        let timezone: String
        let latitude: Double
        let longitude: Double
    }
}

extension IPDataModel {
    /// Preferred alpha-2 for flag and display.
    ///
    /// Resolution order:
    /// 1. `location.country` (English name, e.g. "Taiwan") → alpha-2 via
    ///    `CountryNameMapper`. This follows the IP's actual geo-egress.
    /// 2. `network.autonomous_system.country` (ASN's registered country).
    ///    This is the old behavior and kept as a safety net — for most
    ///    IPs it matches, but for VPN nodes whose ASN is registered in a
    ///    different country than the node itself runs (e.g. a Taiwan
    ///    egress routed via an HK-registered ASN) it gives the wrong
    ///    flag. The name-based path above is the authoritative answer
    ///    when it resolves.
    var countryAlpha2: String {
        if let fromLocation = CountryNameMapper.alpha2(for: location.country) {
            return fromLocation
        }
        return network.autonomousSystem.country.uppercased()
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    var asnLabel: String {
        "AS\(network.autonomousSystem.asn) · \(network.autonomousSystem.name.components(separatedBy: " - ").first ?? network.autonomousSystem.name)"
    }
}
