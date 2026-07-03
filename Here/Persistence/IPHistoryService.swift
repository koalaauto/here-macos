import Foundation

/// Observes egress-IP changes and keeps a capped, persisted chronological
/// list for the History card.
///
/// Storage: `~/Library/Application Support/Here/ip_history.json` — the
/// app ships without App Sandbox (see `Here.entitlements`), so this is
/// the real user Library path, not a sandbox container.
///
/// Two-axis retention:
/// - **Count cap** (`maxEvents`): the chain visualization shows the last
///   5; we keep up to 50 in memory / on disk so users can scroll back
///   if a future UI iteration exposes them. Heavy users rotate out
///   old entries via this.
/// - **Age cap** (`maxAge`): events older than 90 days are dropped on
///   load and on every append. Without this, a light user with sparse
///   history (few changes per year) accumulates events from years ago
///   that aren't useful context. Heavy users hit the count cap first
///   so they never feel the age cap.
actor IPHistoryService {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxEvents: Int
    private let maxAge: TimeInterval

    private var events: [IPChangeEvent]
    private var continuations: [UUID: AsyncStream<[IPChangeEvent]>.Continuation] = [:]

    init(
        fileURL: URL? = nil,
        maxEvents: Int = 50,
        maxAge: TimeInterval = 90 * 24 * 3600
    ) {
        let url = fileURL ?? Self.defaultFileURL()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        self.fileURL = url
        self.encoder = enc
        self.decoder = dec
        self.maxEvents = maxEvents
        self.maxAge = maxAge
        let loaded = Self.loadEvents(from: url, decoder: dec)
        self.events = Self.trim(
            loaded,
            maxEvents: maxEvents,
            maxAge: maxAge,
            now: Date()
        )
    }

    nonisolated func stream() -> AsyncStream<[IPChangeEvent]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    func snapshot() -> [IPChangeEvent] { events }

    /// Record a new egress observation. Deduplicates against the last event
    /// — if the IP hasn't changed, we still touch the `at` of the prior
    /// record? No: we keep the original `at` because the duration rendered
    /// in the UI is "how long have we been at this IP" (from first observed
    /// to now, via the next event's `at`).
    func record(_ model: IPDataModel) {
        if let last = events.last, last.ip == model.ip { return }
        let event = IPChangeEvent.from(model)
        events.append(event)
        events = Self.trim(events, maxEvents: maxEvents, maxAge: maxAge, now: Date())
        saveToDisk()
        emit()
    }

    /// Drop events older than `maxAge` then trim to the most recent
    /// `maxEvents`. Pure / static so the same logic runs on cold-load
    /// (init) and on append (`record`).
    private static func trim(
        _ events: [IPChangeEvent],
        maxEvents: Int,
        maxAge: TimeInterval,
        now: Date
    ) -> [IPChangeEvent] {
        let cutoff = now.addingTimeInterval(-maxAge)
        var fresh = events.filter { $0.at >= cutoff }
        if fresh.count > maxEvents {
            fresh.removeFirst(fresh.count - maxEvents)
        }
        return fresh
    }

    func clear() {
        events.removeAll()
        saveToDisk()
        emit()
    }

    private func register(id: UUID, continuation: AsyncStream<[IPChangeEvent]>.Continuation) {
        continuations[id] = continuation
        continuation.yield(events)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit() {
        for c in continuations.values { c.yield(events) }
    }

    private func saveToDisk() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(events)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.cache.error("Failed to save IP history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadEvents(from url: URL, decoder: JSONDecoder) -> [IPChangeEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([IPChangeEvent].self, from: data)
        } catch {
            Log.cache.error("Failed to load IP history: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func defaultFileURL() -> URL {
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
        return supportDir.appendingPathComponent("ip_history.json", isDirectory: false)
    }
}
