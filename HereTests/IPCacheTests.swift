import Foundation
import Testing

@testable import Here

@Suite("IPCache")
struct IPCacheTests {
    private func makeCache() -> (IPCache, URL) {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("HereTests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("last_ip.json")
        return (IPCache(fileURL: tempFile), tempFile)
    }

    private func sample() -> CachedIP {
        CachedIP(
            model: .init(
                ip: "1.2.3.4",
                network: .init(
                    cidr: "1.2.3.0/24",
                    hosts: .init(start: "1.2.3.1", end: "1.2.3.254"),
                    autonomousSystem: .init(asn: 1, name: "X", organization: "X", country: "US", rir: "ARIN")
                ),
                location: .init(city: "Here", country: "United States", timezone: "UTC", latitude: 0, longitude: 0)
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func roundTrips() {
        let (cache, _) = makeCache()
        let value = sample()
        #expect(cache.save(value))
        let loaded = cache.load()
        #expect(loaded == value)
    }

    @Test func loadReturnsNilWhenMissing() {
        let (cache, _) = makeCache()
        #expect(cache.load() == nil)
    }

    @Test func loadReturnsNilOnCorruption() throws {
        let (cache, url) = makeCache()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not valid json".data(using: .utf8)!.write(to: url)
        #expect(cache.load() == nil)
    }

    @Test func clearRemovesFile() {
        let (cache, url) = makeCache()
        _ = cache.save(sample())
        #expect(FileManager.default.fileExists(atPath: url.path))
        cache.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
