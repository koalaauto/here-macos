import Foundation

/// Selectable download source for the Throughput speed test.
///
/// Each preset is a **complete** download URL — the test just issues a GET
/// and times how fast the response body arrives. No upload probe (upload
/// measurement needs an API-shaped endpoint and doesn't fit the "grab a
/// static file from the nearest CDN" model).
///
/// - `cachefly`: 100 MB test file on Cachefly's CDN. Long-lived global
///   endpoint with wide edge presence; typically hits the nearest POP.
///   Default because it doesn't share the `speed.cloudflare.com` host
///   that some networks SNI-filter.
/// - `cloudflare`: Cloudflare's speed test endpoint with a 100 MB
///   `?bytes=` request.
/// - `custom`: user-provided URL. Any HTTPS resource that serves ≥ 10 MB
///   or so of body works.
enum ThroughputEndpoint: String, CaseIterable, Identifiable, Sendable, Codable {
    case cachefly
    case cloudflare
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cachefly:   String(localized: "Cachefly (100 MB)")
        case .cloudflare: String(localized: "Cloudflare (100 MB)")
        case .custom:     String(localized: "Custom URL")
        }
    }

    /// Complete URL ready to GET. `nil` for `.custom` — the actual URL
    /// lives in `SettingsStore.throughputCustomURL`.
    var presetURL: URL? {
        switch self {
        case .cachefly:
            return URL(string: "https://cachefly.cachefly.net/100mb.test")
        case .cloudflare:
            return URL(string: "https://speed.cloudflare.com/__down?bytes=104857600")
        case .custom:
            return nil
        }
    }
}
