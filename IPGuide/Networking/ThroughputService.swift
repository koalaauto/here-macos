import Foundation

/// On-demand throughput probe against Cloudflare's speed endpoint.
///
/// Download: `GET https://speed.cloudflare.com/__down?bytes=N` — N bytes of
/// random payload. Transfer is timed end-to-end; final Mbps = 8 * bytes /
/// seconds / 1e6.
///
/// Upload: `POST https://speed.cloudflare.com/__up` with a random body; same
/// formula applies.
///
/// Progress reporting: a URLSession delegate (`SpeedProbe`) throttles its
/// `didReceive`/`didSendBodyData` callbacks to ~5 Hz and forwards a rolling
/// Mbps estimate back into the actor. The UI picks up the estimate via
/// `ThroughputStatus.probing(…, liveMbps: …)` and tick-animates the number
/// upwards during the transfer. The FINAL Mbps is computed by the delegate
/// at `didCompleteWithError` and returned from `runProbe`.
actor ThroughputService {
    private let downloadBytes: Int
    private let uploadBytes: Int
    private let estimatedDownloadDuration: TimeInterval = 4.0
    private let estimatedUploadDuration: TimeInterval = 4.0

    private var state: ThroughputStatus
    private var continuations: [UUID: AsyncStream<ThroughputStatus>.Continuation] = [:]
    private var inflight: Task<Void, Never>?
    private let resultURL: URL

    init(
        downloadBytes: Int = 25_000_000,
        uploadBytes: Int = 5_000_000,
        resultURL: URL? = nil
    ) {
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
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

        // Download phase — both blocks start blank.
        state = .probing(
            phase: .download,
            startedAt: Date(),
            estimatedDuration: estimatedDownloadDuration,
            completedDownloadMbps: nil,
            liveMbps: nil
        )
        emit()
        let download = await probeDownload()

        guard let downMbps = download else {
            state = .failed(reason: String(localized: "Download test failed"), lastResult: priorResult)
            emit()
            return
        }

        // Upload phase — carry the freshly-measured download through so the
        // ↓ block can flip from "…" to the real number while ↑ measures.
        state = .probing(
            phase: .upload,
            startedAt: Date(),
            estimatedDuration: estimatedUploadDuration,
            completedDownloadMbps: downMbps,
            liveMbps: nil
        )
        emit()
        let upload = await probeUpload()

        guard let upMbps = upload else {
            state = .failed(reason: String(localized: "Upload test failed"), lastResult: priorResult)
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

    private func probeDownload() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(downloadBytes)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return await runProbe(request: request)
    }

    private func probeUpload() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }

        // Random bytes so no HTTP-layer compression inflates the reading.
        var payload = Data(count: uploadBytes)
        payload.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            arc4random_buf(base, buf.count)
        }

        // Stage the payload to a temp file and hand it to
        // `uploadTask(with:fromFile:)`. Without this — i.e. when the body
        // is set via `URLRequest.httpBody` — URLSession hands the whole
        // buffer to CFNetwork in one go and `didSendBodyData` jumps from
        // 0 to total in a single callback before the bytes are actually
        // on the wire, so the live Mbps number can't tick during the
        // upload. `fromFile:` forces a streaming read that gives us
        // per-chunk progress callbacks as the socket drains.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipguide_up_\(UUID().uuidString).bin")
        do {
            try payload.write(to: tempURL)
        } catch {
            Log.network.debug(
                "Throughput upload: tempfile write failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let mbps = await runProbe(request: request, uploadFromFile: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        return mbps
    }

    /// Shared probe driver: spins up a `SpeedProbe` (URLSession delegate),
    /// forwards the live Mbps estimate back into our state, and resolves
    /// the continuation with the final measured Mbps.
    ///
    /// Pass `uploadFromFile` for upload probes so the session pulls body
    /// bytes from disk in chunks (see the note in `probeUpload`); omit it
    /// for download probes, which use a plain data task.
    private func runProbe(request: URLRequest, uploadFromFile: URL? = nil) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let probe = SpeedProbe(
                onProgress: { [weak self] mbps in
                    Task { await self?.applyLiveMbps(mbps) }
                },
                onComplete: { finalMbps in
                    cont.resume(returning: finalMbps)
                }
            )
            if let fileURL = uploadFromFile {
                probe.runUpload(request: request, fromFile: fileURL)
            } else {
                probe.runDownload(request: request)
            }
        }
    }

    /// Called from `SpeedProbe` callbacks (throttled to ~5 Hz). Updates the
    /// current `.probing` state with the latest rolling Mbps reading so
    /// observers can re-render the active speed block.
    private func applyLiveMbps(_ mbps: Double) {
        guard case .probing(let phase, let startedAt, let estDur, let downloadDone, _) = state else {
            return
        }
        state = .probing(
            phase: phase,
            startedAt: startedAt,
            estimatedDuration: estDur,
            completedDownloadMbps: downloadDone,
            liveMbps: mbps
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

// MARK: - URLSession delegate-based probe

/// One-shot URLSession wrapper that streams Mbps progress callbacks during
/// a transfer and reports the measured final Mbps when the transfer ends.
///
/// Progress is throttled internally to roughly one emit every 200 ms so we
/// don't push the SwiftUI re-render loop on every packet. The session is
/// owned by the probe and invalidated in `didCompleteWithError`.
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
    private let onProgress: @Sendable (Double) -> Void
    private let onComplete: @Sendable (Double?) -> Void

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (Double?) -> Void
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

    func runUpload(request: URLRequest, fromFile: URL) {
        let task = session.uploadTask(with: request, fromFile: fromFile)
        task.resume()
    }

    // Download: response body arrives in chunks.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let b = addBytes(Int64(data.count))
        maybeEmit(bytes: b)
    }

    // Upload: body bytes sent; `totalBytesSent` is absolute.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let b = setBytes(totalBytesSent)
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
            Log.network.debug(
                "Throughput probe failed: \(error.localizedDescription, privacy: .public)"
            )
            onComplete(nil)
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else {
            onComplete(nil)
            return
        }
        onComplete(Double(b) * 8 / elapsed / 1_000_000)
    }

    // MARK: Thread-safe byte accounting

    private func addBytes(_ delta: Int64) -> Int64 {
        lock.lock()
        bytes += delta
        let b = bytes
        lock.unlock()
        return b
    }

    private func setBytes(_ total: Int64) -> Int64 {
        lock.lock()
        bytes = total
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
        onProgress(Double(bytes) * 8 / elapsed / 1_000_000)
    }
}
