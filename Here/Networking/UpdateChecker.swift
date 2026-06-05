import Foundation

/// Polls the GitHub releases API for a newer published version of Here.
///
/// We hit `/repos/bikekoala/here-macos/releases/latest` —
/// unauthenticated, 60 req/hr per client IP. The endpoint already
/// excludes drafts and prereleases server-side; we re-check those
/// flags defensively in case GitHub's semantics shift.
///
/// Why an actor rather than a service that owns mutable state:
/// `UpdateChecker` doesn't track frequency / last-checked-at / skipped
/// versions itself. That state lives in `SettingsStore` so it persists
/// across launches without a separate file. The actor's job is the
/// pure "given the current version, is there something newer?" call —
/// which makes tests easy (inject a mock URLSession via the factory,
/// no defaults plumbing) and keeps the threading rules simple
/// (URLSession's own concurrency, no shared mutable state).
///
/// Distribution context: Here is unsigned. We don't auto-download or
/// auto-install; the "update available" UI just opens the release
/// page in the user's browser. If we ever get a Developer ID, this
/// is the right spot to bolt on Sparkle-style background updates,
/// reusing the same release feed.
actor UpdateChecker {
    /// Result the caller surfaces in the UI when something newer
    /// than `currentVersion` is available.
    struct UpdateInfo: Equatable, Sendable {
        /// `tag_name` with the leading `v` stripped — `"0.30.0"`.
        let latestVersion: String
        let releaseName: String
        /// Browser-friendly release page. Used as fallback when no
        /// DMG asset is attached to the release.
        let releaseURL: URL
        /// Direct DMG download URL extracted from the release's
        /// `assets[*].browser_download_url`. `nil` for legacy
        /// releases without a DMG attached. The in-app installer
        /// pulls this via URLSession (no Gatekeeper quarantine xattr,
        /// unlike browser downloads) and replaces the running app.
        let dmgURL: URL?
        let releaseNotes: String
        let publishedAt: Date?
    }

    private let endpoint: URL
    private let sessionFactory: @Sendable () -> URLSession
    private let currentVersion: String

    init(
        currentVersion: String = AppVersion.current,
        endpoint: URL = URL(string: "https://api.github.com/repos/bikekoala/here-macos/releases/latest")!,
        sessionFactory: @escaping @Sendable () -> URLSession = UpdateChecker.makeSession
    ) {
        self.currentVersion = currentVersion
        self.endpoint = endpoint
        self.sessionFactory = sessionFactory
    }

    static func makeSession() -> URLSession {
        // Same shape as IPWhoIsProvider — system proxy aware via
        // `.default`, no caching, modest timeout. The check is
        // best-effort and shouldn't hold the app up; 15 s is plenty
        // for a single GET against api.github.com under normal
        // conditions and short enough that a flaky mobile hop fails
        // fast.
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            // GitHub recommends pinning the API version explicitly to
            // insulate against breaking schema changes.
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": AppUserAgent.value
        ]
        return URLSession(configuration: config)
    }

    /// Hit GitHub once. Returns:
    /// - `.some(UpdateInfo)` when the latest published release is
    ///   strictly newer than `currentVersion`,
    /// - `nil` when we're already on / ahead of latest, or the
    ///   release is a draft / prerelease.
    /// Throws on network / HTTP / decode failures so the caller can
    /// distinguish "no update" from "couldn't check".
    func checkForUpdate() async throws -> UpdateInfo? {
        let session = sessionFactory()
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"

        let (data, response): (Data, URLResponse)
        do {
            // `safeData(for:)` — NSException barrier, see v0.32.1
            // (URLSession+Safe.swift). Otherwise an exception from
            // `taskForClassInfo:` would crash the app inside the
            // daily update-check timer instead of failing the check.
            (data, response) = try await session.safeData(for: request)
        } catch {
            throw UpdateCheckError.from(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.http(http.statusCode)
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder.githubISO.decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.decoding(error.localizedDescription)
        }

        if release.draft == true || release.prerelease == true {
            Log.update.info("Latest release is draft/prerelease; ignoring")
            return nil
        }

        let latest = Self.normalize(tag: release.tagName)
        guard !latest.isEmpty else {
            throw UpdateCheckError.decoding("Empty tag_name")
        }

        switch Self.compare(latest, currentVersion) {
        case .orderedDescending:
            // Pick the first `.dmg` asset. We only ever publish one
            // DMG per release; if that ever changes the installer can
            // grow a more careful filter (e.g. by version-in-name).
            let dmgURL = release.assets?
                .first(where: { $0.name.hasSuffix(".dmg") })?
                .browserDownloadURL
            return UpdateInfo(
                latestVersion: latest,
                releaseName: release.name?.isEmpty == false ? release.name! : release.tagName,
                releaseURL: release.htmlURL,
                dmgURL: dmgURL,
                releaseNotes: release.body ?? "",
                publishedAt: release.publishedAt
            )
        case .orderedAscending, .orderedSame:
            return nil
        }
    }

    // MARK: - Pure helpers (exposed for tests)

    /// Strip a single leading `v` / `V` from a release tag so
    /// `"v0.30.0"` and `"0.30.0"` compare equal.
    static func normalize(tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" {
            s.removeFirst()
        }
        return s
    }

    /// Numeric compare on two `MAJOR.MINOR.PATCH` strings. Missing
    /// components default to 0 (`"1.0"` == `"1.0.0"`). Non-numeric
    /// segments are coerced to `-1` so anything weird sorts below
    /// real versions — we'd rather miss a release than spam users
    /// with a bogus "update available" prompt for a malformed tag.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? -1 }
        let pb = b.split(separator: ".").map { Int($0) ?? -1 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let l = i < pa.count ? pa[i] : 0
            let r = i < pb.count ? pb[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}

// MARK: - Wire format

/// Subset of GitHub's release payload we care about. Many other
/// fields exist (assets, author, reactions, …) but we don't read
/// them — keeping the struct narrow means a schema addition won't
/// break the decoder.
struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let body: String?
    let publishedAt: Date?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [Asset]?

    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let browserDownloadURL: URL
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }
}

// MARK: - Error

enum UpdateCheckError: Error, Equatable, Sendable {
    case offline
    case timeout
    case transport(String)
    case http(Int)
    case decoding(String)
    case cancelled

    var userDescription: String {
        switch self {
        case .offline:
            String(localized: "No network connection.")
        case .timeout:
            String(localized: "The update check timed out.")
        case .transport(let msg):
            String(localized: "Couldn't reach GitHub: \(msg)")
        case .http(let code):
            String(localized: "GitHub returned an error (\(code)).")
        case .decoding:
            String(localized: "Couldn't read GitHub's response.")
        case .cancelled:
            String(localized: "Update check cancelled.")
        }
    }

    static func from(_ error: Error) -> UpdateCheckError {
        if let e = error as? UpdateCheckError { return e }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
                return .offline
            case NSURLErrorCancelled: return .cancelled
            default: return .transport(nsError.localizedDescription)
            }
        }
        return .transport(error.localizedDescription)
    }
}

// MARK: - Bundle version + GitHub date helpers

/// Convenience wrapper around `CFBundleShortVersionString`. Lives
/// alongside the update checker because it's the only consumer
/// today; promote to a top-level utility if a second caller appears.
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

private extension JSONDecoder {
    /// GitHub's `published_at` is RFC 3339 but uses `Z` suffix without
    /// fractional seconds. Use a custom strategy to be lenient about
    /// either form, since GitHub has historically tightened this.
    static let githubISO: JSONDecoder = {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = plain.date(from: raw) { return date }
            if let date = withFraction.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised ISO date: \(raw)"
            )
        }
        return decoder
    }()
}
