import Foundation

protocol IPProvider: Sendable {
    var name: String { get }
    func fetch() async throws -> IPDataModel
}

struct IPGuideProvider: IPProvider {
    let name = "ip.guide"
    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = IPGuideProvider.makeSession(),
        endpoint: URL = URL(string: "https://ip.guide/")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Both timeouts set to 10 s so any single fetch can't exceed
        // ~10 s wall-clock — the resource timeout caps total time
        // (connect + request + response) regardless of whether data
        // is trickling in.
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": IPGuideProvider.userAgent
        ]
        return URLSession(configuration: config)
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return "Here/\(version) (macOS)"
    }

    func fetch() async throws -> IPDataModel {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw IPServiceError.from(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw IPServiceError.transport(message: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IPServiceError.http(statusCode: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(IPDataModel.self, from: data)
        } catch {
            throw IPServiceError.decoding(message: error.localizedDescription)
        }
    }
}
