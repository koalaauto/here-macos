import Foundation
import Testing

@testable import Here

/// Suite-private URLProtocol so we don't fight other suites over
/// `URLProtocolMock`'s class-static handler. Both suites are
/// `.serialized` internally, but Swift Testing runs different suites
/// in parallel — and a class-static handler is a single global slot.
/// The race surfaced as "test A's HTTP 503 handler swallows test B's
/// URLError throw and vice versa". Giving this suite its own
/// `URLProtocol` subclass (different class object → different static
/// slot) eliminates the cross-suite contention without needing a
/// process-wide lock.
final class UpdateMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?
    private static let lock = NSLock()

    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        self.handler = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateMockURLProtocol.self]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        UpdateMockURLProtocol.lock.lock()
        let h = UpdateMockURLProtocol.handler
        UpdateMockURLProtocol.lock.unlock()
        guard let h else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try h(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("UpdateChecker", .serialized)
struct UpdateCheckerTests {

    // MARK: - Pure helpers

    /// `compare` is the heart of the "is there a newer version?"
    /// decision. It needs to handle the day-to-day cases (patch /
    /// minor / major bumps) and the awkward ones (different segment
    /// counts, leading-v tags, garbage). Any drift here would either
    /// silently miss real updates or spam users with bogus prompts.
    @Test func compareHandlesNumericSemver() {
        #expect(UpdateChecker.compare("0.30.0", "0.29.3") == .orderedDescending)
        #expect(UpdateChecker.compare("0.29.3", "0.30.0") == .orderedAscending)
        #expect(UpdateChecker.compare("0.29.3", "0.29.3") == .orderedSame)
        #expect(UpdateChecker.compare("1.0.0", "0.99.99") == .orderedDescending)
    }

    /// "1.0" should match "1.0.0" — semver allows omitting trailing
    /// zero components. Not strictly a case GitHub will produce given
    /// our tagging convention, but defensive against a future change.
    @Test func compareTreatsMissingComponentsAsZero() {
        #expect(UpdateChecker.compare("1.0", "1.0.0") == .orderedSame)
        #expect(UpdateChecker.compare("1.0.1", "1.0") == .orderedDescending)
    }

    /// Whitespace and a leading `v` shouldn't keep us from
    /// recognising equality.
    @Test func normalizeStripsWhitespaceAndLeadingV() {
        #expect(UpdateChecker.normalize(tag: "v0.30.0") == "0.30.0")
        #expect(UpdateChecker.normalize(tag: "  v0.30.0  ") == "0.30.0")
        #expect(UpdateChecker.normalize(tag: "V0.30.0") == "0.30.0")
        #expect(UpdateChecker.normalize(tag: "0.30.0") == "0.30.0")
    }

    /// Prerelease suffix recognition. Atom feeds don't distinguish
    /// prereleases from final releases the way the JSON API did, so
    /// we filter by tag-name suffix. Cover the common suffixes plus
    /// confirm the normal case is not a false positive.
    @Test func recognisesPrereleaseTags() {
        #expect(UpdateChecker.isPrereleaseTag("0.30.0-beta") == true)
        #expect(UpdateChecker.isPrereleaseTag("0.30.0-rc1") == true)
        #expect(UpdateChecker.isPrereleaseTag("0.30.0-alpha2") == true)
        #expect(UpdateChecker.isPrereleaseTag("0.30.0-pre") == true)
        #expect(UpdateChecker.isPrereleaseTag("0.30.0") == false)
        #expect(UpdateChecker.isPrereleaseTag("1.0.0") == false)
    }

    // MARK: - End-to-end via URLProtocol + atom XML

    private func mockedChecker(currentVersion: String) -> UpdateChecker {
        UpdateChecker(
            currentVersion: currentVersion,
            feedURL: URL(string: "https://mock.github.com/releases.atom")!,
            downloadURLBase: URL(string: "https://mock.github.com/releases/download")!,
            sessionFactory: { UpdateMockURLProtocol.session() }
        )
    }

    private func httpResponse(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://mock.github.com/releases.atom")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/atom+xml"]
        )!
    }

    /// Build an atom feed body containing the provided entries
    /// (newest-first, mirroring GitHub's natural ordering). Tags get
    /// rendered with the `v` prefix because that's how GitHub
    /// formats them in the real feed.
    private func atomFeed(entries: [(tag: String, body: String)]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/" xml:lang="en-US">
          <id>tag:github.com,2008:https://github.com/koalaauto/here-macos/releases</id>
          <link type="text/html" rel="alternate" href="https://github.com/koalaauto/here-macos/releases"/>
          <title>Release notes from here-macos</title>
          <updated>2026-06-23T03:31:06Z</updated>
        """
        for entry in entries {
            let tagWithV = entry.tag.hasPrefix("v") ? entry.tag : "v\(entry.tag)"
            // Mimic GitHub's HTML-escaped content. The parser keeps
            // the escaped form verbatim, so tests assert on what the
            // raw atom emits.
            let escapedBody = entry.body
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            xml += """

              <entry>
                <id>tag:github.com,2008:Repository/0/\(tagWithV)</id>
                <updated>2026-04-30T12:00:00Z</updated>
                <link rel="alternate" type="text/html" href="https://github.com/koalaauto/here-macos/releases/tag/\(tagWithV)"/>
                <title>\(tagWithV)</title>
                <content type="html">\(escapedBody)</content>
                <author><name>koalaauto</name></author>
                <media:thumbnail height="30" width="30" url="https://example.com/avatar.png"/>
              </entry>
        """
        }
        xml += "\n</feed>\n"
        return Data(xml.utf8)
    }

    /// Happy path: feed has a newer tag at the top, current is older
    /// → checker reports an `UpdateInfo` populated with version,
    /// release page URL, and synthesized DMG URL. The DMG URL is the
    /// most fragile new piece — we synthesize it from the version
    /// rather than read it out of the feed (atom doesn't list
    /// assets) — so the test pins the convention explicitly.
    @Test func reportsUpdateAvailableWhenTagIsNewer() async throws {
        let feed = atomFeed(entries: [
            (tag: "v0.30.0", body: "<h2>Changes</h2><ul><li>Auto update support</li></ul>")
        ])
        UpdateMockURLProtocol.install { _ in (self.httpResponse(200), feed) }
        defer { UpdateMockURLProtocol.clear() }

        let checker = mockedChecker(currentVersion: "0.29.3")
        let info = try await checker.checkForUpdate()
        #expect(info != nil)
        #expect(info?.latestVersion == "0.30.0")
        #expect(info?.releaseURL.absoluteString.hasSuffix("/releases/tag/v0.30.0") == true)
        #expect(info?.dmgURL?.absoluteString == "https://mock.github.com/releases/download/v0.30.0/Here-0.30.0.dmg")
        // Notes carry through with HTML; the coordinator's
        // `summarize` strips it for the alert.
        #expect(info?.releaseNotes.contains("Auto update support") == true)
    }

    /// Already on latest → nil. Important: the user shouldn't ever see
    /// a "0.30.0 is available" prompt while running 0.30.0.
    @Test func returnsNilWhenAlreadyOnLatest() async throws {
        let feed = atomFeed(entries: [(tag: "v0.30.0", body: "")])
        UpdateMockURLProtocol.install { _ in (self.httpResponse(200), feed) }
        defer { UpdateMockURLProtocol.clear() }

        let checker = mockedChecker(currentVersion: "0.30.0")
        let info = try await checker.checkForUpdate()
        #expect(info == nil)
    }

    /// User on a build newer than the published latest (dev build,
    /// time-traveller, whatever) → still nil. We never tell someone
    /// to "downgrade".
    @Test func returnsNilWhenAheadOfLatest() async throws {
        let feed = atomFeed(entries: [(tag: "v0.30.0", body: "")])
        UpdateMockURLProtocol.install { _ in (self.httpResponse(200), feed) }
        defer { UpdateMockURLProtocol.clear() }

        let checker = mockedChecker(currentVersion: "0.31.0")
        let info = try await checker.checkForUpdate()
        #expect(info == nil)
    }

    /// Prerelease at the top of the feed gets skipped; the next
    /// final-release entry is what we compare against. This is the
    /// only meaningful filtering we can do — atom feeds don't carry
    /// a structured `prerelease` flag the way the JSON API did.
    @Test func skipsPrereleaseEntries() async throws {
        let feed = atomFeed(entries: [
            (tag: "v0.31.0-beta", body: "<p>beta</p>"),
            (tag: "v0.30.0", body: "<p>final</p>")
        ])
        UpdateMockURLProtocol.install { _ in (self.httpResponse(200), feed) }
        defer { UpdateMockURLProtocol.clear() }

        let checker = mockedChecker(currentVersion: "0.29.3")
        let info = try await checker.checkForUpdate()
        #expect(info?.latestVersion == "0.30.0")
    }

    /// 5xx from github.com → `.http(503)` so the coordinator can
    /// decide whether to surface or swallow it.
    @Test func surfacesHTTPErrors() async throws {
        UpdateMockURLProtocol.install { _ in (self.httpResponse(503), Data()) }
        defer { UpdateMockURLProtocol.clear() }

        do {
            _ = try await mockedChecker(currentVersion: "0.29.3").checkForUpdate()
            Issue.record("Expected throw on 503")
        } catch let error as UpdateCheckError {
            if case .http(let code) = error {
                #expect(code == 503)
            } else {
                Issue.record("Expected .http(503), got \(error)")
            }
        }
    }

    /// Network drop → `.offline`, not the raw URLError. Lets the
    /// coordinator render the right user-facing string.
    @Test func translatesURLErrorIntoOffline() async throws {
        UpdateMockURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        defer { UpdateMockURLProtocol.clear() }

        do {
            _ = try await mockedChecker(currentVersion: "0.29.3").checkForUpdate()
            Issue.record("Expected throw")
        } catch let error as UpdateCheckError {
            #expect(error == .offline)
        }
    }

    /// Garbage body → `.decoding`, not a crash. The atom feed parser
    /// throws when the document isn't well-formed XML.
    @Test func surfacesDecodingFailureOnGarbage() async throws {
        UpdateMockURLProtocol.install { _ in
            (self.httpResponse(200), Data("<<not valid xml>>".utf8))
        }
        defer { UpdateMockURLProtocol.clear() }

        do {
            _ = try await mockedChecker(currentVersion: "0.29.3").checkForUpdate()
            Issue.record("Expected throw")
        } catch let error as UpdateCheckError {
            if case .decoding = error {
                // OK
            } else {
                Issue.record("Expected .decoding, got \(error)")
            }
        }
    }

    /// Empty feed (no <entry> children) → nil, no crash. Defensive
    /// in case GitHub ever serves an empty atom for a repo with no
    /// releases yet — unlikely for us, but cheap to cover.
    @Test func returnsNilForEmptyFeed() async throws {
        let feed = atomFeed(entries: [])
        UpdateMockURLProtocol.install { _ in (self.httpResponse(200), feed) }
        defer { UpdateMockURLProtocol.clear() }

        let info = try await mockedChecker(currentVersion: "0.29.3").checkForUpdate()
        #expect(info == nil)
    }

    // MARK: - Coordinator helper

    /// `UpdateCoordinator.summarize` strips markdown headers and
    /// caps length so the alert doesn't expand to fill the screen.
    @MainActor
    @Test func summarizeStripsMarkdownAndCapsLength() {
        let raw = """
        ## Install
        - Download
        - Drag

        ## Changes
        - Auto update added
        - Other fix
        """
        let s = UpdateCoordinator.summarize(notes: raw, maxLines: 3, maxChars: 200)
        // Headers (`## `) stripped; bullet leaders (`- `) stripped.
        #expect(!s.contains("##"))
        #expect(!s.contains("- "))
        #expect(s.split(separator: "\n").count <= 3)
    }

    @MainActor
    @Test func summarizeFallsBackForEmptyNotes() {
        let s = UpdateCoordinator.summarize(notes: "")
        #expect(!s.isEmpty)
    }

    // MARK: - Frequency model

    /// Cadence values must align with what the picker offers and what
    /// the coordinator keys off — drift would mean the user picks
    /// "weekly" and gets a daily prompt, or vice versa.
    @Test func frequencyIntervalsAreCorrect() {
        #expect(UpdateCheckFrequency.never.interval == nil)
        #expect(UpdateCheckFrequency.daily.interval == TimeInterval(24 * 60 * 60))
        #expect(UpdateCheckFrequency.weekly.interval == TimeInterval(7 * 24 * 60 * 60))
    }
}
