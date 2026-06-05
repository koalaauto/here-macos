import Foundation

/// On-demand download throughput probe.
///
/// Takes a complete URL (from a `ThroughputEndpoint` preset or the user's
/// custom URL), issues `GET`, and times how fast the response body arrives.
/// A URLSession delegate (`SpeedProbe`) watches `didReceive(data:)`, which
/// is a reliable real-time throughput signal because bytes arrive from the
/// peer across the wire. Delegate-reported `Content-Length` drives the
/// progress bar; the final Mbps is `bytes * 8 / (now - firstByteAt) / 1e6`
/// — the timer starts when the **first body byte** lands, not at request
/// build time, so DNS / TCP / TLS / request-send / response-headers time
/// is excluded from the denominator. (A pure "total elapsed" denominator
/// like `wget` reports, where handshake counts as part of "transfer time",
/// produces 30-50% under-reporting on fat pipes against tools like
/// fast.com that measure sustained throughput.)
///
/// Upload measurement was removed in v0.21.0 — it didn't fit the
/// "grab-a-static-file-from-the-nearest-CDN" model and the
/// `didSendBodyData`-based live number was fundamentally dishonest on
/// slow uplinks (reports socket-buffer intake, not peer ACKs).
actor ThroughputService {
    private var state: ThroughputStatus
    private var continuations: [UUID: AsyncStream<ThroughputStatus>.Continuation] = [:]
    private var inflight: Task<Void, Never>?
    private let resultURL: URL

    init(resultURL: URL? = nil) {
        let url = resultURL ?? Self.defaultResultURL()
        self.resultURL = url
        self.state = .idle(lastResult: Self.loadResult(from: url))
    }

    nonisolated func stream() -> AsyncStream<ThroughputStatus> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    func snapshot() -> ThroughputStatus { state }

    /// Kick off a download probe. Coalesces concurrent calls.
    func runTest(url: URL) async {
        if inflight != nil { return }
        let task = Task<Void, Never> { [weak self] in await self?.performTest(url: url) }
        inflight = task
        await task.value
        inflight = nil
    }

    /// Surface a failure state without a network call. Used when the
    /// current endpoint settings can't produce a usable URL (e.g. Custom
    /// URL is blank or malformed) — we'd rather show the user why nothing
    /// ran than silently substitute a different source.
    func reportLocalFailure(reason: String) {
        if inflight != nil { return }
        state = .failed(reason: reason, lastResult: state.lastResult)
        emit()
    }

    // MARK: Implementation

    private func performTest(url: URL) async {
        let priorResult = state.lastResult

        state = .probing(liveMbps: nil, liveProgress: 0)
        emit()

        let result = await probeDownload(url: url)

        switch result {
        case .success(let mbps):
            let finished = ThroughputResult(downloadMbps: mbps, testedAt: Date())
            saveResult(finished)
            state = .idle(lastResult: finished)
            emit()
        case .failure(let error):
            state = .failed(
                reason: Self.failureReason(error: error),
                lastResult: priorResult
            )
            emit()
        }
    }

    private func probeDownload(url: URL) async -> Result<Double, Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return await runProbe(request: request)
    }

    /// Drive a `SpeedProbe` for one download, forwarding the progress
    /// callbacks into our `.probing` state and resolving with the final
    /// Mbps when the transfer completes.
    private func runProbe(request: URLRequest) async -> Result<Double, Error> {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<Double, Error>, Never>) in
            let probe = SpeedProbe(
                onProgress: { [weak self] mbps, progress in
                    Task { await self?.applyLiveProgress(mbps: mbps, progress: progress) }
                },
                onComplete: { result in
                    cont.resume(returning: result)
                }
            )
            probe.run(request: request)
        }
    }

    private func applyLiveProgress(mbps: Double, progress: Double) {
        guard case .probing = state else { return }
        state = .probing(
            liveMbps: mbps,
            liveProgress: min(1.0, max(0.0, progress))
        )
        emit()
    }

    private func register(id: UUID, continuation: AsyncStream<ThroughputStatus>.Continuation) {
        continuations[id] = continuation
        continuation.yield(state)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit() {
        for c in continuations.values { c.yield(state) }
    }

    // MARK: Failure messaging

    /// Use the system's localized description so the user sees the real
    /// error (e.g. "An SSL error has occurred…", "The request timed out.")
    /// rather than a one-size-fits-all translation. Runtime diagnostic
    /// signal beats a tidy pill.
    private static func failureReason(error: Error) -> String {
        error.localizedDescription
    }

    // MARK: Persistence

    private func saveResult(_ result: ThroughputResult) {
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            try data.write(to: resultURL, options: [.atomic])
        } catch {
            Log.cache.error("Failed to save throughput result: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadResult(from url: URL) -> ThroughputResult? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ThroughputResult.self, from: data)
        } catch {
            return nil
        }
    }

    private static func defaultResultURL() -> URL {
        let supportDir: URL
        do {
            supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Here", isDirectory: true)
        } catch {
            supportDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("Here", isDirectory: true)
        }
        return supportDir.appendingPathComponent("throughput_last.json", isDirectory: false)
    }
}

// MARK: - URLSession delegate-based download probe

/// One-shot URLSession wrapper for a download measurement. Emits a
/// throttled stream of `(mbps, progress)` as bytes arrive and resolves
/// with the final Mbps at completion.
///
/// Progress is computed from the response's `Content-Length` header:
/// `progress = bytesReceived / expected`. If the server omits the header
/// (chunked encoding, dynamic endpoints), we fall back to a 100 MB
/// assumption so the bar still advances visually — the number stays
/// accurate regardless.
///
/// Throttle ~5 Hz so we don't hammer the SwiftUI update loop on fast
/// pipes.
///
/// **Thread safety**: `delegateQueue: nil` in the URLSession init
/// (see `init` below) means URLSession dispatches all delegate
/// callbacks on its own private serial queue. Every place we read
/// or write the mutable instance state (`bytes`, `firstByteAt`,
/// `expectedBytes`, `lastEmit`, `finished`) is called from one of
/// those delegate methods, so the state is **already serialised
/// by URLSession** — we used to wrap each access in an `NSLock`
/// but that was redundant paranoia. Removing it shortens hot paths.
/// The captured `onProgress` / `onComplete` closures are immutable
/// `@Sendable` and called from the same serial queue. The
/// `@unchecked Sendable` is honest about the situation: Swift's
/// type system can't know about URLSession's queue invariant.
private final class SpeedProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession!
    /// Wall-clock at the moment the **first body byte** arrived.
    /// `nil` until the first `didReceive(data:)` callback. Using
    /// first-byte (instead of init time) means we don't penalise
    /// the reported Mbps with DNS resolution + TCP handshake +
    /// TLS handshake + request-send time + response-headers time
    /// — none of which are throughput, all of which used to drag
    /// the average down toward "wget total-time mode" instead of
    /// "fast.com sustained-throughput mode" (typical 30–50% under-
    /// reporting on fat pipes).
    private var firstByteAt: Date?
    private var bytes: Int64 = 0
    private var expectedBytes: Int64 = 100 * 1024 * 1024  // fallback
    private var lastEmit = Date.distantPast
    private var finished = false
    private let onProgress: @Sendable (_ mbps: Double, _ progress: Double) -> Void
    private let onComplete: @Sendable (Result<Double, Error>) -> Void

    init(
        onProgress: @escaping @Sendable (_ mbps: Double, _ progress: Double) -> Void,
        onComplete: @escaping @Sendable (Result<Double, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        super.init()
        // `URLSessionConfiguration.default` (not `.ephemeral`) so the
        // download inherits the user's system proxy — the throughput
        // we report is the path the popover's IP came in over, not
        // a back-channel that silently bypasses Clash / Surge / etc.
        // Latency, IP service, and throughput are now consistent on
        // this point.
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": AppUserAgent.value]
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func run(request: URLRequest) {
        // `safeDataTask(with:)` — the synchronous `session.dataTask(with:)`
        // can throw an Obj-C `NSException` from `taskForClassInfo:` under
        // certain proxy/utun states. With our delegate-driven design that
        // exception would never reach a `catch` (the call is on the actor
        // path before any await), so it would crash the whole app instead
        // of just failing this probe. v0.32.1 — see URLSession+Safe.swift.
        let task: URLSessionDataTask
        do {
            task = try session.safeDataTask(with: request)
        } catch {
            onComplete(.failure(error))
            return
        }
        task.resume()
    }

    // Response received — snapshot Content-Length for progress calculation.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let reported = response.expectedContentLength
        if reported > 0 {
            expectedBytes = reported
        }
        completionHandler(.allow)
    }

    // Response body chunk arrived.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Stamp first-byte time on the very first chunk. The bytes
        // in this chunk are still counted — the resulting tiny bias
        // (a few KB attributed to ~0 elapsed) is negligible against
        // a 100 MB total.
        if firstByteAt == nil {
            firstByteAt = Date()
        }
        bytes += Int64(data.count)
        maybeEmit(bytes: bytes, expected: expectedBytes, start: firstByteAt)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !finished else { return }
        finished = true
        let b = bytes
        let start = firstByteAt

        session.finishTasksAndInvalidate()

        if let error {
            Log.network.error(
                "Throughput probe failed: \(error.localizedDescription, privacy: .public)"
            )
            onComplete(.failure(error))
            return
        }
        // No body bytes ever arrived → there's no throughput to
        // report. (Could happen on a redirect-to-empty, server
        // returning 204, …) Surface as zero-byte rather than a
        // misleading divide-by-near-zero number.
        guard let start, b > 0 else {
            onComplete(.failure(URLError(.zeroByteResource)))
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else {
            onComplete(.failure(URLError(.zeroByteResource)))
            return
        }
        onComplete(.success(Double(b) * 8 / elapsed / 1_000_000))
    }

    /// Throttle progress emits to ~5 Hz; skip the first ~150 ms
    /// after the first byte where the elapsed denominator is too
    /// small for a stable readout. `start` is the first-byte
    /// timestamp passed in from the data callback (always non-nil
    /// here since we only call this from inside a `didReceive(data:)`
    /// after stamping it).
    private func maybeEmit(bytes: Int64, expected: Int64, start: Date?) {
        guard let start else { return }
        let now = Date()
        guard now.timeIntervalSince(lastEmit) > 0.2 else { return }
        lastEmit = now

        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0.15 else { return }
        let mbps = Double(bytes) * 8 / elapsed / 1_000_000
        let progress = min(1.0, max(0.0, Double(bytes) / Double(max(1, expected))))
        onProgress(mbps, progress)
    }
}
