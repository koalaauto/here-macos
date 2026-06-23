import Foundation

/// Polls the GitHub releases atom feed for a newer published version
/// of Here.
///
/// We hit `https://github.com/koalaauto/here-macos/releases.atom` —
/// the same data GitHub exposes to RSS readers, served by `github.com`
/// rather than `api.github.com`. Critically, this endpoint is **not
/// subject to the api.github.com 60-req/hour/IP unauthenticated
/// limit** that we observed during v0.33.0 development: VPN users
/// sharing an egress IP (any Clash / Surge community node, corporate
/// NAT, university network) routinely burn through the 60/hour pool
/// just from a handful of users daily-checking, after which every
/// Check Now returns HTTP 403 with no useful diagnostic.
///
/// The atom feed has served GitHub's RSS reader ecosystem for ~15
/// years and is the closest thing to a "stable web URL" GitHub
/// offers for release data. Tradeoffs vs the JSON API path it
/// replaces (v0.30.0–v0.32.1):
///
/// - **No rate limit (or one so high we'd never approach it).** This
///   is the whole reason for the swap.
/// - **No structured `assets[]`.** The feed lists release metadata
///   but doesn't enumerate uploaded files. We synthesize the DMG URL
///   from our naming convention (`Here-X.Y.Z.dmg` at the standard
///   download path). Stable as long as we keep that convention; any
///   release that breaks it would silently break in-app updates for
///   users hitting that release. Worth a one-line warning in the
///   release checklist if we ever change it.
/// - **No structured `draft` / `prerelease` booleans.** Drafts aren't
///   in the feed at all (good — they shouldn't be public). Pre-
///   releases ARE in the feed; we filter by tag-name suffix
///   (`-beta`, `-rc`, `-alpha`, `-pre`). We've never shipped a
///   prerelease so this is belt-and-braces.
///
/// Why an actor rather than a service that owns mutable state:
/// `UpdateChecker` doesn't track frequency / last-checked-at /
/// skipped versions itself. That state lives in `SettingsStore`. The
/// actor's job is the pure "given the current version, is there
/// something newer?" call.
///
/// Distribution context: Here is unsigned. We don't auto-download or
/// auto-install on this path; the "update available" UI hands off
/// to `UpdateInstaller`, which uses the synthesized DMG URL — that's
/// a regular `github.com/.../releases/download/...` link, which is
/// **also** not subject to api.github.com rate limits.
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
        /// Direct DMG download URL synthesized from the convention
        /// `https://github.com/<owner>/<repo>/releases/download/v<X.Y.Z>/Here-<X.Y.Z>.dmg`.
        /// `nil` only if we couldn't construct the URL at all (i.e.
        /// the version string is malformed enough that even the
        /// release URL came back broken — should never happen). The
        /// in-app installer pulls this via URLSession (no Gatekeeper
        /// quarantine xattr, unlike browser downloads) and replaces
        /// the running app.
        let dmgURL: URL?
        let releaseNotes: String
        let publishedAt: Date?
    }

    private let feedURL: URL
    private let downloadURLBase: URL
    private let sessionFactory: @Sendable () -> URLSession
    private let currentVersion: String

    init(
        currentVersion: String = AppVersion.current,
        feedURL: URL = URL(string: "https://github.com/koalaauto/here-macos/releases.atom")!,
        downloadURLBase: URL = URL(string: "https://github.com/koalaauto/here-macos/releases/download")!,
        sessionFactory: @escaping @Sendable () -> URLSession = UpdateChecker.makeSession
    ) {
        self.currentVersion = currentVersion
        self.feedURL = feedURL
        self.downloadURLBase = downloadURLBase
        self.sessionFactory = sessionFactory
    }

    static func makeSession() -> URLSession {
        // Same shape as IPWhoIsProvider — system proxy aware via
        // `.default`, no caching, modest timeout. The check is
        // best-effort and shouldn't hold the app up; 15 s is plenty
        // for a single GET against github.com under normal conditions
        // and short enough that a flaky mobile hop fails fast.
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "Accept": "application/atom+xml",
            "User-Agent": AppUserAgent.value
        ]
        return URLSession(configuration: config)
    }

    /// Hit GitHub once. Returns:
    /// - `.some(UpdateInfo)` when the latest published release is
    ///   strictly newer than `currentVersion`,
    /// - `nil` when we're already on / ahead of latest, or every
    ///   entry in the feed was a prerelease.
    /// Throws on network / HTTP / parse failures so the caller can
    /// distinguish "no update" from "couldn't check".
    func checkForUpdate() async throws -> UpdateInfo? {
        let session = sessionFactory()
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: feedURL)
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

        let entries: [AtomEntry]
        do {
            entries = try AtomFeedParser.parse(data: data)
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.decoding(error.localizedDescription)
        }

        // Walk entries newest-first (GitHub's feed is already sorted
        // that way). Skip prereleases by tag suffix. First match wins.
        for entry in entries {
            let normalized = Self.normalize(tag: entry.title)
            if normalized.isEmpty { continue }
            if Self.isPrereleaseTag(normalized) {
                Log.update.info("Skipping prerelease entry: \(entry.title, privacy: .public)")
                continue
            }
            switch Self.compare(normalized, currentVersion) {
            case .orderedDescending:
                return UpdateInfo(
                    latestVersion: normalized,
                    releaseName: entry.title,
                    releaseURL: entry.link,
                    dmgURL: synthesizeDMGURL(version: normalized),
                    releaseNotes: entry.htmlContent,
                    publishedAt: entry.updated
                )
            case .orderedAscending, .orderedSame:
                // First non-prerelease entry is already <= current.
                // Older entries below it are necessarily older too;
                // nothing left to check.
                return nil
            }
        }
        return nil
    }

    /// Construct the DMG download URL for a given version. By
    /// convention every release uploads `Here-X.Y.Z.dmg` to the
    /// standard releases/download path. Stable as long as we keep
    /// that convention (see file header).
    private func synthesizeDMGURL(version: String) -> URL? {
        downloadURLBase
            .appendingPathComponent("v\(version)")
            .appendingPathComponent("Here-\(version).dmg")
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

    /// Recognise prerelease tags by their suffix. We've never shipped
    /// one, so this is belt-and-braces against a future hand-error
    /// (someone publishes `v1.0.0-beta` and forgets to mark it
    /// prerelease in GitHub — though even then, the feed wouldn't
    /// distinguish, so suffix detection is the only signal we have).
    static func isPrereleaseTag(_ normalized: String) -> Bool {
        let lower = normalized.lowercased()
        let suffixes = ["-beta", "-rc", "-alpha", "-pre", "-dev", "-nightly"]
        return suffixes.contains { lower.contains($0) }
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

// MARK: - Atom feed model + parser

/// One `<entry>` we care about. The atom feed contains a few extras
/// (`<author>`, `<media:thumbnail>`, `<id>`) we ignore.
struct AtomEntry: Equatable, Sendable {
    /// `<title>` — the release tag, e.g. `"v0.33.0"`.
    let title: String
    /// `<link rel="alternate" href="...">` — release page URL.
    let link: URL
    /// `<updated>` — RFC 3339 publish/edit timestamp.
    let updated: Date?
    /// `<content type="html">...</content>` — HTML-escaped release
    /// notes. Consumers can either render the HTML or strip it; the
    /// `UpdateCoordinator.summarize` path treats it as markdown-ish
    /// plain text and the leading `&lt;h2&gt;` tags fall out fine.
    let htmlContent: String
}

/// Foundation `XMLParser`-based atom feed reader. Streams elements
/// rather than DOM-walking — atom feeds are small (~10KB) but
/// streaming keeps memory predictable and the code linear.
enum AtomFeedParser {
    static func parse(data: Data) throws -> [AtomEntry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw UpdateCheckError.decoding(
                parser.parserError?.localizedDescription ?? "Atom feed parse failed"
            )
        }
        return delegate.entries
    }

    /// `XMLParserDelegate` implementation. State machine:
    /// `entries` accumulates finalised entries; `currentEntry` is
    /// the partial entry while inside an `<entry>` element;
    /// `currentElement` / `textBuffer` capture characters into the
    /// active field.
    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [AtomEntry] = []

        private struct PartialEntry {
            var title: String?
            var link: URL?
            var updated: Date?
            var content: String?
        }
        private var currentEntry: PartialEntry?
        private var currentElement: String?
        private var textBuffer = ""

        /// GitHub's atom feed `<updated>` is RFC 3339 with `Z` suffix,
        /// no fractional seconds. Try both forms — `ISO8601DateFormatter`
        /// isn't `Sendable`, so we build instances locally per call
        /// rather than caching them as static state. Cost is trivial:
        /// at most one parse per update check, which itself runs at
        /// most daily.
        private func parseDate(_ raw: String) -> Date? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: raw) { return d }
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return withFraction.date(from: raw)
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            if elementName == "entry" {
                currentEntry = PartialEntry()
                return
            }
            // Only track fields when we're inside an entry. The
            // feed-level <title>, <updated>, <link> at the top of the
            // document refer to the feed itself, not a release.
            guard currentEntry != nil else { return }

            currentElement = elementName
            textBuffer = ""

            // <link> carries its value in the `href` attribute, not
            // as element text. Capture it on the start tag — the
            // matching </link> has nothing to add.
            if elementName == "link", let href = attributeDict["href"], let url = URL(string: href) {
                // Atom allows multiple <link> elements with different
                // `rel`; we only want `rel="alternate"` (the human-
                // readable release page). Missing `rel` defaults to
                // alternate per the spec.
                let rel = attributeDict["rel"] ?? "alternate"
                if rel == "alternate" && currentEntry?.link == nil {
                    currentEntry?.link = url
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard currentEntry != nil, currentElement != nil else { return }
            textBuffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard currentEntry != nil, currentElement != nil else { return }
            if let s = String(data: CDATABlock, encoding: .utf8) {
                textBuffer += s
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "entry" {
                if let e = currentEntry,
                   let title = e.title,
                   let link = e.link {
                    entries.append(AtomEntry(
                        title: title,
                        link: link,
                        updated: e.updated,
                        htmlContent: e.content ?? ""
                    ))
                }
                currentEntry = nil
                currentElement = nil
                textBuffer = ""
                return
            }

            guard currentEntry != nil, elementName == currentElement else {
                // Closing a nested element (e.g. <name> inside <author>)
                // or an element we don't track. Either way, don't
                // commit the buffer.
                if elementName == currentElement { currentElement = nil }
                return
            }

            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "title":
                if currentEntry?.title == nil { currentEntry?.title = value }
            case "updated":
                if currentEntry?.updated == nil { currentEntry?.updated = parseDate(value) }
            case "content":
                if currentEntry?.content == nil { currentEntry?.content = value }
            default:
                break
            }
            currentElement = nil
            textBuffer = ""
        }
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
            String(localized: "Couldn't reach the update server: \(msg)")
        case .http(let code):
            String(localized: "The update server returned an error (\(code)).")
        case .decoding:
            String(localized: "Couldn't read the update server's response.")
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

// MARK: - Bundle version helper

/// Convenience wrapper around `CFBundleShortVersionString`. Lives
/// alongside the update checker because it's the only consumer
/// today; promote to a top-level utility if a second caller appears.
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
