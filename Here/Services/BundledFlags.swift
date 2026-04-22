import Foundation

/// Catalog of every alpha-2 code we have a bundled flag asset for.
///
/// Used by the status-bar "unknown" placeholder: when the egress isn't
/// verified (`.idle / .loading / .error`), we render a random flag + the
/// sentinel text "OO". The random choice makes state transitions visible
/// and keeps the widget feeling alive; the "OO" text is the honest signal
/// that we don't actually know the country.
///
/// The list is pinned to what's in `Resources/Assets.xcassets/Flags/` at
/// build time. If new flag assets are added, append their alpha-2 here
/// (and conversely on removal) — `FlagRenderer` relies on the imageset
/// being present.
enum BundledFlags {
    /// 252 alpha-2 codes, covering nearly all of ISO 3166-1 plus a few
    /// common exonyms (XK for Kosovo, UN, EU) that `ip.guide` occasionally
    /// emits via its ASN metadata.
    static let allCodes: [String] = [
        "AD", "AE", "AF", "AG", "AI", "AL", "AM", "AO", "AQ", "AR",
        "AS", "AT", "AU", "AW", "AX", "AZ", "BA", "BB", "BD", "BE",
        "BF", "BG", "BH", "BI", "BJ", "BL", "BM", "BN", "BO", "BQ",
        "BR", "BS", "BT", "BV", "BW", "BY", "BZ", "CA", "CC", "CD",
        "CF", "CG", "CH", "CI", "CK", "CL", "CM", "CN", "CO", "CR",
        "CU", "CV", "CW", "CX", "CY", "CZ", "DE", "DJ", "DK", "DM",
        "DO", "DZ", "EC", "EE", "EG", "EH", "ER", "ES", "ET", "EU",
        "FI", "FJ", "FK", "FM", "FO", "FR", "GA", "GB", "GD", "GE",
        "GF", "GG", "GH", "GI", "GL", "GM", "GN", "GP", "GQ", "GR",
        "GS", "GT", "GU", "GW", "GY", "HK", "HM", "HN", "HR", "HT",
        "HU", "ID", "IE", "IL", "IM", "IN", "IO", "IQ", "IR", "IS",
        "IT", "JE", "JM", "JO", "JP", "KE", "KG", "KH", "KI", "KM",
        "KN", "KP", "KR", "KW", "KY", "KZ", "LA", "LB", "LC", "LI",
        "LK", "LR", "LS", "LT", "LU", "LV", "LY", "MA", "MC", "MD",
        "ME", "MF", "MG", "MH", "MK", "ML", "MM", "MN", "MO", "MP",
        "MQ", "MR", "MS", "MT", "MU", "MV", "MW", "MX", "MY", "MZ",
        "NA", "NC", "NE", "NF", "NG", "NI", "NL", "NO", "NP", "NR",
        "NU", "NZ", "OM", "PA", "PE", "PF", "PG", "PH", "PK", "PL",
        "PM", "PN", "PR", "PS", "PT", "PW", "PY", "QA", "RE", "RO",
        "RS", "RU", "RW", "SA", "SB", "SC", "SD", "SE", "SG", "SH",
        "SI", "SJ", "SK", "SL", "SM", "SN", "SO", "SR", "SS", "ST",
        "SV", "SX", "SY", "SZ", "TC", "TD", "TF", "TG", "TH", "TJ",
        "TK", "TL", "TM", "TN", "TO", "TR", "TT", "TV", "TW", "TZ",
        "UA", "UG", "UM", "UN", "US", "UY", "UZ", "VA", "VC", "VE",
        "VG", "VI", "VN", "VU", "WF", "WS", "XK", "YE", "YT", "ZA",
        "ZM", "ZW"
    ]

    /// Pick a random alpha-2 code. Optionally excludes a specific code
    /// (typically the user's last-known country) so the random pick is
    /// visibly different from whatever the widget was showing before —
    /// otherwise a lucky collision would make the state transition
    /// invisible.
    static func randomCode(excluding: String? = nil) -> String {
        if let excluded = excluding?.uppercased() {
            let pool = allCodes.filter { $0 != excluded }
            return pool.randomElement() ?? "GG"
        }
        return allCodes.randomElement() ?? "GG"
    }
}
