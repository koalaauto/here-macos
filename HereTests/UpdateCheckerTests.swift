import Foundation
import Testing

@testable import Here

/// Suite-private URLProtocol so we don't fight `IPWhoIsProviderTests`
/// over `URLProtocolMock`'s class-static handler. Both suites are
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

    // MARK: - End-to-end via URLProtocolMock

    private func mockedChecker(currentVersion: String) -> UpdateChecker {
        UpdateChecker(
            currentVersion: currentVersion,
            endpoint: URL(string: "https://mock.api.github.com/releases/latest")!,
            sessionFactory: { UpdateMockURLProtocol.session() }
        )
    }

    private func httpResponse(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://mock.api.github.com/releases/latest")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func releaseJSON(
        tag: String = "v0.30.0",
        name: String? = "v0.30.0",
        draft: Bool = false,
        prerelease: Bool = false,
        body: String = "## Changes\n- Auto update support"
    ) -> Data {
        // Hand-build the JSON to avoid pulling in a proper encoder
        // — the wire shape is small and we want to test the decoder
        // against literal GitHub-like bytes.
        let nameField: String
        if let name {
            nameField = "\"\(name)\""
        } else {
            nameField = "null"
        }
        let json = """
        {
          "tag_name": "\(tag)",
          "name": \(nameField),
          "html_url": "https://github.com/bikekoala/here-macos/releases/tag/\(tag)",
          "body": \(escape(body)),
          "published_at": "2026-04-30T12:00:00Z",
          "draft": \(draft),
          "prerelease": \(prerelease)
        }
        """
        return Data(json.utf8)
    }

    private func escape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// Happy path: GitHub returns a newer tag, current is older →
    /// checker reports an `UpdateInfo`.
    @Test func reportsUpdateAvailableWhenTagIsNewer() async throws {
        UpdateMockURLProtocol.install { _ in (self.httpResponse(200), self.releaseJSON()) }
        defer { UpdateMockURLProtocol.clear() }

        let checker = mockedChecker(currentVersion: "0.29.3")
        let info = try await checker.checkForUpdate()
        #expect(info != nil)
        #expect(info?.latestVersion == "0.30.0")
        #expect(info?.releaseURL.absoluteString.contains("0.30.0") == true)
    }

    /// Already on latest → nil. Important: the user shouldn't ever see
    /// a "0.30.0 is available" prompt while running 0.30.0.
    @Test func returnsNilWhenAlreadyOnLatest() async throws {
        UpdateMockURLProtocol.install { _ in (self.httpResponse(200), self.releaseJSON(tag: "v0.30.0")) }
        defer { UpdateMockURLProtocol.clear() }

        let checker = mockedChecker(currentVersion: "0.30.0")
        let info = try await checker.checkForUpdate()
        #expect(info == nil)
    }

    /// User on a build newer than the published latest (dev build,
    /// time-traveller, whatever) → still nil. We never tell someone
    /// to "downgrade".
    @Test func returnsNilWhenAheadOfLatest() async throws {
        UpdateMockURLProtocol.install { _ in (self.httpResponse(200), self.releaseJSON(tag: "v0.30.0")) }
        defer { UpdateMockURLProtocol.clear() }

        let checker = mockedChecker(currentVersion: "0.31.0")
        let info = try await checker.checkForUpdate()
        #expect(info == nil)
    }

    /// Drafts shouldn't surface even if their tag sorts newer —
    /// `releases/latest` already filters them server-side, but we
    /// belt-and-braces.
    @Test func ignoresDraftsAndPrereleases() async throws {
        UpdateMockURLProtocol.install { _ in
            (self.httpResponse(200), self.releaseJSON(tag: "v0.31.0", draft: true))
        }
        defer { UpdateMockURLProtocol.clear() }

        let checker = mockedChecker(currentVersion: "0.30.0")
        #expect(try await checker.checkForUpdate() == nil)

        UpdateMockURLProtocol.install { _ in
            (self.httpResponse(200), self.releaseJSON(tag: "v0.31.0", prerelease: true))
        }
        #expect(try await checker.checkForUpdate() == nil)
    }

    /// 5xx from GitHub → `.http(503)` so the coordinator can decide
    /// whether to surface or swallow it.
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

    /// Garbage body → `.decoding`, not a crash.
    @Test func surfacesDecodingFailureOnGarbage() async throws {
        UpdateMockURLProtocol.install { _ in
            (self.httpResponse(200), Data("<html>not json</html>".utf8))
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
