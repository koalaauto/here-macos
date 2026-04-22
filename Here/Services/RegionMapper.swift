import CoreLocation
import Foundation

protocol ReverseGeocoding: Sendable {
    func lookup(latitude: Double, longitude: Double) async -> String?
}

struct AppleReverseGeocoder: ReverseGeocoding {
    func lookup(latitude: Double, longitude: Double) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.first?.administrativeArea
        } catch {
            Log.geocode.debug("reverseGeocodeLocation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

actor RegionMapper {
    private struct Key: Hashable {
        let country: String
        let city: String
    }

    private let geocoder: ReverseGeocoding
    private var memoryCache: [Key: String] = [:]

    init(geocoder: ReverseGeocoding = AppleReverseGeocoder()) {
        self.geocoder = geocoder
    }

    func regionCode(for model: IPDataModel) async -> String {
        let key = Key(country: model.countryAlpha2, city: model.location.city)
        if let cached = memoryCache[key] { return cached }

        if let raw = await geocoder.lookup(latitude: model.location.latitude, longitude: model.location.longitude),
           !raw.isEmpty {
            let normalized = Self.normalize(administrativeArea: raw, country: model.countryAlpha2)
            memoryCache[key] = normalized
            return normalized
        }

        let fallback = Self.cityInitials(model.location.city)
        memoryCache[key] = fallback
        return fallback
    }

    static func normalize(administrativeArea: String, country: String) -> String {
        let trimmed = administrativeArea.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 2, trimmed.allSatisfy({ $0.isLetter }) {
            return trimmed.uppercased()
        }
        if let mapped = Self.knownAdministrativeAreaToISO[country]?[trimmed.lowercased()] {
            return mapped
        }
        return cityInitials(trimmed)
    }

    /// Derive a 2-letter region code from a city name when no ISO 3166-2 data is available.
    /// Uses word initials for multi-word cities ("San Jose" → "SJ", "Los Angeles" → "LA"),
    /// and the first two letters for single-word cities ("Beijing" → "BE").
    static func cityInitials(_ city: String) -> String {
        let stripped = (city.applyingTransform(.stripDiacritics, reverse: false) ?? city)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = stripped.split { !$0.isLetter }
        if words.count >= 2 {
            let initials = words.prefix(3).compactMap { $0.first }
            if initials.count >= 2 {
                let joined = String(initials.prefix(2))
                return joined.uppercased()
            }
        }
        let letters = stripped.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let prefix = String(String.UnicodeScalarView(letters.prefix(2)))
        return prefix.uppercased().isEmpty ? "??" : prefix.uppercased()
    }

    // Minimal bundled table for cases where CLGeocoder returns full names.
    // Extend over time; city initials is acceptable fallback for unknowns.
    static let knownAdministrativeAreaToISO: [String: [String: String]] = [
        "US": [
            "california": "CA", "new york": "NY", "texas": "TX", "washington": "WA",
            "oregon": "OR", "nevada": "NV", "arizona": "AZ", "colorado": "CO",
            "illinois": "IL", "massachusetts": "MA", "florida": "FL", "georgia": "GA",
            "virginia": "VA", "pennsylvania": "PA", "ohio": "OH", "michigan": "MI",
            "new jersey": "NJ", "north carolina": "NC", "district of columbia": "DC"
        ],
        "CA": [
            "ontario": "ON", "quebec": "QC", "british columbia": "BC",
            "alberta": "AB", "manitoba": "MB", "saskatchewan": "SK"
        ],
        "CN": [
            "beijing": "BJ", "shanghai": "SH", "guangdong": "GD",
            "zhejiang": "ZJ", "jiangsu": "JS", "sichuan": "SC", "hubei": "HB"
        ],
        "JP": [
            "tokyo": "TK", "osaka": "OS", "kanagawa": "KN", "aichi": "AI"
        ],
        "GB": [
            "england": "EN", "scotland": "SC", "wales": "WL", "northern ireland": "NI"
        ],
        "DE": [
            "berlin": "BE", "bavaria": "BY", "hesse": "HE", "hamburg": "HH"
        ],
        "AU": [
            "new south wales": "NS", "victoria": "VI", "queensland": "QL",
            "western australia": "WA", "south australia": "SA"
        ]
    ]
}
