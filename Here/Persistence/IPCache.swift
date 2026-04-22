import Foundation

struct CachedIP: Codable, Equatable, Sendable {
    let model: IPDataModel
    let fetchedAt: Date
}

final class IPCache: Sendable {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? IPCache.defaultFileURL()
        self.encoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            e.dateEncodingStrategy = .iso8601
            return e
        }()
        self.decoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()
    }

    func load() -> CachedIP? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(CachedIP.self, from: data)
        } catch {
            Log.cache.error("Failed to load cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func save(_ cached: CachedIP) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(cached)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            Log.cache.error("Failed to save cache: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func defaultFileURL() -> URL {
        let supportDir: URL
        do {
            supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Here", isDirectory: true)
        } catch {
            supportDir = FileManager.default.temporaryDirectory.appendingPathComponent("Here", isDirectory: true)
        }
        return supportDir.appendingPathComponent("last_ip.json", isDirectory: false)
    }
}
