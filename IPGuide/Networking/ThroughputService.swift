import Foundation

/// On-demand throughput probe against Cloudflare's speed endpoint.
///
/// Download: `GET https://speed.cloudflare.com/__down?bytes=N` — N random
/// bytes. A URLSession delegate (`SpeedProbe`) watches `didReceive(data:)`
/// and forwards a rolling Mbps estimate into the actor ~5 Hz so the UI
/// can tick up the live number; the final Mbps is the total bytes over
/// the full elapsed time.
///
/// Upload: `POST https://speed.cloudflare.com/__up` — split into
/// `uploadChunkCount` sequential chunks of `uploadChunkBytes` each.
/// Delegate-based progress doesn't work for uploads (see `probeUpload`
/// for the full write-up on `didSendBodyData` measuring socket-buffer
/// intake, not peer ACKs); instead we time each chunk end-to-end and
/// report the running aggregate after every chunk.
actor ThroughputService {
    private let downloadBytes: Int

    /// Upload is split into N chunks so the live number reflects real
    /// throughput samples (each chunk's end-to-end timing). See the note in
    /// `probeUpload` for the full reasoning.
    private let uploadChunkCount = 5
    private let uploadChunkBytes = 1_000_000

    private var state: ThroughputStatus
    private var continuations: [UUID: AsyncStream<ThroughputStatus>.Continuation] = [:]
    private var inflight: Task<Void, Never>?
    private let resultURL: URL

    init(
        downloadBytes: Int = 25_000_000,
        resultURL: URL? = nil
    ) {
        self.downloadBytes = downloadBytes
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

    /// Kick off a download + upload probe. Coalesces concurrent calls.
    func runTest() async {
        if inflight != nil { return }
        let task = Task<Void, Never> { [weak self] in await self?.performTest() }
        inflight = task
        await task.value
        inflight = nil
    }

    // MARK: Implementation

    private func performTest() async {
        let priorResult = state.lastResult

        // Download phase — both blocks start blank, progress at 0.
        state = .probing(
            phase: .download,
            completedDownloadMbps: nil,
            liveMbps: nil,
            liveProgress: 0
        )
        emit()
        let downloadResult = await probeDownload()

        let downMbps: Double
        switch downloadResult {
        case .success(let value):
            downMbps = value
        case .failure(let error):
            state = .failed(
                reason: Self.failureReason(
                    prefix: String(localized: "Download"),
                    error: error
                ),
                lastResult: priorResult
            )
            emit()
            return
        }

        // Upload phase — carry the freshly-measured download through so the
        // ↓ block can flip from "…" to the real number while ↑ measures.
        state = .probing(
            phase: .upload,
            completedDownloadMbps: downMbps,
            liveMbps: nil,
            liveProgress: 0
        )
        emit()
        let uploadResult = await probeUpload()

        let upMbps: Double
        switch uploadResult {
        case .success(let value):
            upMbps = value
        case .failure(let error):
            state = .failed(
                reason: Self.failureReason(
                    prefix: String(localized: "Upload"),
                    error: error
                ),
                lastResult: priorResult
            )
            emit()
            return
        }

        let result = ThroughputResult(
            downloadMbps: downMbps,
            uploadMbps: upMbps,
            testedAt: Date()
        )
        saveResult(result)
        state = .idle(lastResult: result)
        emit()
    }

    private func probeDownload() async -> Result<Double, Error> {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(downloadBytes)") else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return await runProbe(request: request)
    }

    /// Upload probe — runs `uploadChunkCount` sequential POST requests of
    /// `uploadChunkBytes` each, rather than one big POST.
    ///
    /// Why not one big streamed POST? Because `didSendBodyData` fires as
    /// bytes enter the kernel socket buffer, NOT as the peer acknowledges
    /// them. On a slow uplink the sequence looks like:
    /// 1. URLSession hands the whole payload to the kernel in ~100 ms
    ///    (bus speed) → first progress callback reports something like
    ///    "5 MB in 0.2 s" → apparent 200 Mbps (entirely fictional).
    /// 2. Kernel buffer is full; URLSession blocks for many seconds
    ///    waiting for TCP ACKs. No more progress callbacks fire.
    /// 3. `didCompleteWithError` lands eventually with the real total
    ///    time, so the FINAL number is correct — but the live number
    ///    spent the whole test lying.
    ///
    /// Sequential small POSTs sidestep this: each `await session.data(for:)`
    /// only resumes when the server returns a response, which in turn only
    /// happens after the full POST body has actually reached the server.
    /// So each chunk's end-to-end timing is a truthful throughput sample.
    /// We report the running aggregate after every chunk so the UI ticks
    /// up with real data.
    private func probeUpload() async -> Result<Double, Error> {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else {
            return .failure(URLError(.badURL))
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": IPGuideProvider.userAgent]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var totalBytes: Int64 = 0
        var totalElapsed: TimeInterval = 0

        for chunk in 0..<uploadChunkCount {
            // Fresh random bytes per chunk so intermediaries can't cache or
            // compress us into fake speed.
            var payload = Data(count: uploadChunkBytes)
            payload.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress else { return }
                arc4random_buf(base, buf.count)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload

            let start = Date()
            do {
                _ = try await session.data(for: request)
            } catch {
                Log.network.error(
                    "Throughput upload chunk \(chunk) failed: \(error.localizedDescription, privacy: .public)"
                )
                // Partial success: if we already have some samples, report
                // what we measured rather than calling the whole test a bust.
                if totalBytes > 0 && totalElapsed > 0 {
                    return .success(Double(totalBytes) * 8 / totalElapsed / 1_000_000)
                }
                return .failure(error)
            }
            let elapsed = Date().timeIntervalSince(start)

            totalBytes += Int64(uploadChunkBytes)
            totalElapsed += elapsed

            // Running aggregate Mbps — each new chunk's sample pulls the
            // number toward the steady-state value rather than replacing it.
            // Progress bar jumps in `1 / uploadChunkCount` steps as each
            // chunk's end-to-end timing lands.
            let mbps = Double(totalBytes) * 8 / totalElapsed / 1_000_000
            let progress = Double(chunk + 1) / Double(uploadChunkCount)
            applyLiveProgress(mbps: mbps, progress: progress)
        }

        guard totalElapsed > 0 else { return .failure(URLError(.zeroByteResource)) }
        return .success(Double(totalBytes) * 8 / totalElapsed / 1_000_000)
    }

    /// Download probe driver — spins up a `SpeedProbe` (URLSession delegate
    /// that watches `didReceive(data:)`, which is a reliable real-time
    /// throughput signal because bytes arrive from the peer over the wire),
    /// forwards the live Mbps + byte progress back into our state, and
    /// resolves the continuation with the final measured Mbps.
    private func runProbe(request: URLRequest) async -> Result<Double, Error> {
        let totalBytes = downloadBytes
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<Double, Error>, Never>) in
            let probe = SpeedProbe(
                onProgress: { [weak self] mbps, bytes in
                    // Real byte-based progress: bytes received divided by
                    // the total we requested from the endpoint. When this
                    // hits 1.0 the transfer has genuinely arrived.
                    let progress = min(1.0, max(0.0, Double(bytes) / Double(totalBytes)))
                    Task { await self?.applyLiveProgress(mbps: mbps, progress: progress) }
                },
                onComplete: { result in
                    cont.resume(returning: result)
                }
            )
            probe.runDownload(request: request)
        }
    }

    /// Called from the per-direction progress path. Updates the current
    /// `.probing` state with the latest rolling Mbps + transfer progress so
    /// observers can re-render the active speed block and advance the bar.
    private func applyLiveProgress(mbps: Double, progress: Double) {
        guard case .probing(let phase, let downloadDone, _, _) = state else {
            return
        }
        state = .probing(
            phase: phase,
            completedDownloadMbps: downloadDone,
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

    // MARK: Persistence of the last result

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

    /// Translate a URLSession failure into a user-visible one-line reason.
    /// Picks a short phrase for the common `URLError.Code` values so the
    /// failure pill in the card actually tells you what's wrong (e.g.
    /// "Download: TLS handshake failed" vs just "Download test failed"),
    /// and falls through to `localizedDescription` for anything else.
    private static func failureReason(prefix: String, error: Error) -> String {
        let detail: String
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                detail = String(localized: "no internet")
            case .networkConnectionLost:
                detail = String(localized: "connection lost")
            case .timedOut:
                detail = String(localized: "timed out")
            case .cannotFindHost, .dnsLookupFailed:
                detail = String(localized: "can't reach host")
            case .cannotConnectToHost:
                detail = String(localized: "host refused")
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                detail = String(localized: "TLS handshake failed")
            case .zeroByteResource:
                detail = String(localized: "empty response")
            default:
                detail = urlError.localizedDescription
            }
        } else {
            detail = error.localizedDescription
        }
        return "\(prefix): \(detail)"
    }

    private static func defaultResultURL() -> URL {
        let supportDir: URL
        do {
            supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("IPGuide", isDirectory: true)
        } catch {
            supportDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("IPGuide", isDirectory: true)
        }
        return supportDir.appendingPathComponent("throughput_last.json", isDirectory: false)
    }
}

// MARK: - URLSession delegate-based download probe

/// One-shot URLSession wrapper used only for DOWNLOAD probes. Streams Mbps
/// progress callbacks as response bytes arrive and reports the measured
/// final Mbps at completion.
///
/// For downloads, `didReceive(data:)` is a reliable real-time throughput
/// signal because bytes arrive from the peer across the wire. For uploads
/// the analogous delegate method (`didSendBodyData`) is not useful because
/// it fires when bytes enter the kernel socket buffer, not when the peer
/// ACKs them — so we use sequential small POSTs with end-to-end timing
/// instead (see `ThroughputService.probeUpload`).
///
/// Progress is throttled to ~5 Hz so we don't push the SwiftUI update loop
/// on every packet. The session is owned by the probe and invalidated in
/// `didCompleteWithError`.
///
/// `@unchecked Sendable` is safe here because all mutable state sits behind
/// an `NSLock` and the delegate callbacks land on URLSession's private
/// serial delegate queue.
private final class SpeedProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let startedAt = Date()
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var lastEmit = Date.distantPast
    private var finished = false
    private let onProgress: @Sendable (_ mbps: Double, _ bytes: Int64) -> Void
    private let onComplete: @Sendable (Result<Double, Error>) -> Void

    init(
        onProgress: @escaping @Sendable (_ mbps: Double, _ bytes: Int64) -> Void,
        onComplete: @escaping @Sendable (Result<Double, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // Long enough to cover proxied connections on slow pipes.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": IPGuideProvider.userAgent]
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func runDownload(request: URLRequest) {
        let task = session.dataTask(with: request)
        task.resume()
    }

    // Download: response body arrives in chunks.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let b = addBytes(Int64(data.count))
        maybeEmit(bytes: b)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let b = bytes
        lock.unlock()

        session.finishTasksAndInvalidate()

        if let error {
            Log.network.error(
                "Throughput download probe failed: \(error.localizedDescription, privacy: .public)"
            )
            onComplete(.failure(error))
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else {
            onComplete(.failure(URLError(.zeroByteResource)))
            return
        }
        onComplete(.success(Double(b) * 8 / elapsed / 1_000_000))
    }

    // MARK: Thread-safe byte accounting

    private func addBytes(_ delta: Int64) -> Int64 {
        lock.lock()
        bytes += delta
        let b = bytes
        lock.unlock()
        return b
    }

    /// Throttle progress emits to ~5 Hz. Without this the delegate would
    /// call `onProgress` hundreds of times per second on a fast pipe and
    /// overwhelm the actor/SwiftUI update chain.
    private func maybeEmit(bytes: Int64) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastEmit) > 0.2 else {
            lock.unlock()
            return
        }
        lastEmit = now
        lock.unlock()

        let elapsed = now.timeIntervalSince(startedAt)
        // Skip the first ~150 ms — TCP/TLS handshake dominates early numbers
        // and they lie about the steady-state throughput.
        guard elapsed > 0.15 else { return }
        let mbps = Double(bytes) * 8 / elapsed / 1_000_000
        onProgress(mbps, bytes)
    }
}
