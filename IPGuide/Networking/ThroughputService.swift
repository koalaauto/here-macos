import Foundation

/// On-demand throughput probe against Cloudflare's speed endpoint.
///
/// Download: `GET https://speed.cloudflare.com/__down?bytes=N` — N bytes of
/// random payload. Transfer is timed end-to-end; Mbps = 8 * bytes / seconds
/// / 1e6.
///
/// Upload: `POST https://speed.cloudflare.com/__up` with a random body; Mbps
/// computed the same way.
///
/// V1 doesn't stream live Mbps during the test — the UI fakes a linear
/// progress bar from `startedAt` over `estimatedDuration` while the transfer
/// is in flight, then animates the final number in. Accurate final readings,
/// much simpler wiring.
actor ThroughputService {
    private let session: URLSession

    private let downloadBytes: Int
    private let uploadBytes: Int
    /// How long we tell the UI to animate the progress bar over. Tuned to
    /// ~typical transfer time for the payload sizes on a decent residential
    /// connection; the actual transfer may finish slightly earlier or later.
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
        let config = URLSessionConfiguration.ephemeral
        // Generous timeouts so a proxied upload (often slower than the pipe
        // itself) can still complete. `timeoutIntervalForRequest` is the
        // idle-between-packets timer; `timeoutIntervalForResource` bounds
        // the whole transfer including the server's response.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": IPGuideProvider.userAgent]
        self.session = URLSession(configuration: config)
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

    func estimatedDurations() -> (download: TimeInterval, upload: TimeInterval) {
        (estimatedDownloadDuration, estimatedUploadDuration)
    }

    // MARK: Implementation

    private func performTest() async {
        let priorResult = state.lastResult

        // Download phase
        state = .probing(
            direction: .download,
            startedAt: Date(),
            estimatedDuration: estimatedDownloadDuration,
            lastResult: priorResult
        )
        emit()
        let download = await probeDownload()

        guard let downMbps = download else {
            state = .failed(reason: String(localized: "Download test failed"), lastResult: priorResult)
            emit()
            return
        }

        // Upload phase
        state = .probing(
            direction: .upload,
            startedAt: Date(),
            estimatedDuration: estimatedUploadDuration,
            lastResult: priorResult
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
        let start = Date()
        do {
            let (data, _) = try await session.data(from: url)
            let elapsed = max(0.001, Date().timeIntervalSince(start))
            return Double(data.count) * 8 / elapsed / 1_000_000
        } catch {
            Log.network.debug("Throughput download failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func probeUpload() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // Random bytes to avoid any intermediate compression inflating the
        // throughput reading.
        var payload = Data(count: uploadBytes)
        payload.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            arc4random_buf(base, buf.count)
        }
        request.httpBody = payload
        let start = Date()
        do {
            _ = try await session.data(for: request)
            let elapsed = max(0.001, Date().timeIntervalSince(start))
            return Double(payload.count) * 8 / elapsed / 1_000_000
        } catch {
            Log.network.debug("Throughput upload failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
