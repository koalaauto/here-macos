import Foundation

/// Maps full English country names (as returned by ip.guide's
/// `location.country` field) to ISO 3166-1 alpha-2 codes.
///
/// Why this exists: for VPN traffic, the ASN's registered country
/// (`network.autonomous_system.country`) often doesn't match the IP's
/// actual geo-country. A user egressing in Taiwan through a VPN whose
/// ASN is registered in Hong Kong will have the ASN country = "HK" but
/// `location.country` = "Taiwan" — and we want the flag to follow the
/// egress, not the ASN paperwork. So the flag path prefers a name-based
/// lookup against `location.country` first, and only falls back to the
/// ASN country when the name can't be resolved.
enum CountryNameMapper {
    /// Resolve an English country name to its ISO alpha-2 code.
    ///
    /// Lookup strategy:
    /// 1. Exact (case-insensitive) match — covers the common case where
    ///    ip.guide's spelling matches Apple's `Locale` name verbatim
    ///    ("Taiwan", "United States", "Japan", …).
    /// 2. Substring fallback — tolerant to name drift like
    ///    "Taiwan, Province of China" vs the shorter "Taiwan". We accept
    ///    either direction of containment. When several candidates match,
    ///    prefer the one whose length is closest to the input to avoid
    ///    mapping a short input onto a long compound name (e.g. a bare
    ///    "Congo" shouldn't collapse onto "Congo - Kinshasa").
    static func alpha2(for englishName: String) -> String? {
        let key = englishName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return nil }

        if let direct = nameMap[key] { return direct }

        var best: (delta: Int, code: String)?
        for (candidateKey, candidateCode) in nameMap {
            let matches = candidateKey.contains(key) || key.contains(candidateKey)
            guard matches else { continue }
            let delta = abs(candidateKey.count - key.count)
            if best == nil || delta < best!.delta {
                best = (delta, candidateCode)
            }
        }
        return best?.code
    }

    /// `english-name (lowercased) → UPPERCASE alpha-2` table, built once at
    /// first access from `Locale.Region.isoRegions`.
    private static let nameMap: [String: String] = {
        // Force English names regardless of the user's locale — the lookup
        // key comes from ip.guide which returns English.
        let english = Locale(identifier: "en_US_POSIX")
        var map: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            // Only bilateral country codes. Skips macro-regions like "001"
            // (World), "150" (Europe), "419" (Latin America).
            guard region.identifier.count == 2 else { continue }
            guard let name = english.localizedString(forRegionCode: region.identifier) else {
                continue
            }
            map[name.lowercased()] = region.identifier.uppercased()
        }
        return map
    }()
}
