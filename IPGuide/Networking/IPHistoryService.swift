import Foundation

/// Observes egress-IP changes and keeps a capped, persisted chronological
/// list for the History card.
///
/// Storage: `~/…/Application Support/IPGuide/ip_history.json` (sandbox
/// container for the signed bundle). Capped at `maxEvents` events; oldest
/// entries are trimmed on append.
actor IPHistoryService {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxEvents: Int

    private var events: [IPChangeEvent]
    private var continuations: [UUID: AsyncStream<[IPChangeEvent]>.Continuation] = [:]

    init(fileURL: URL? = nil, maxEvents: Int = 50) {
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
        self.events = Self.loadEvents(from: url, decoder: dec)
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
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        saveToDisk()
        emit()
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
            ).appendingPathComponent("IPGuide", isDirectory: true)
        } catch {
            supportDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("IPGuide", isDirectory: true)
        }
        return supportDir.appendingPathComponent("ip_history.json", isDirectory: false)
    }
}
