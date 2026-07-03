import Foundation

/// Convenience wrapper around `CFBundleShortVersionString`. Shared by
/// the update checker (version compare) and `AppUserAgent` (identifier
/// string) — both read the same Info.plist key, so it lives here rather
/// than being duplicated.
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

/// Shared `User-Agent` string for every outbound HTTP request the app
/// makes — IP lookup, latency probes, throughput downloads. Centralising
/// keeps formatting consistent and makes "swap our identifier" a
/// one-line change.
enum AppUserAgent {
    static var value: String {
        "Here/\(AppVersion.current) (macOS)"
    }
}
