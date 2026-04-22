import Foundation

struct LatencySample: Sendable, Equatable, Identifiable, Codable {
    let id: UUID
    let at: Date
    /// Measured round-trip in milliseconds. `nil` means the probe timed out or errored.
    let latencyMs: Double?

    init(id: UUID = UUID(), at: Date = Date(), latencyMs: Double?) {
        self.id = id
        self.at = at
        self.latencyMs = latencyMs
    }
}

enum LatencyBucket: Sendable {
    case empty          // never probed
    case good           // < greenMaxMs
    case moderate       // green..<yellow
    case slow           // yellow..<orange
    case poor           // >= orange, OR timeout / network error

    static func classify(_ sample: LatencySample?, thresholds: LatencyThresholds) -> LatencyBucket {
        guard let sample else { return .empty }
        // Timeout / error collapses into the worst severity bucket (red).
        guard let ms = sample.latencyMs else { return .poor }
        if ms < thresholds.greenMaxMs { return .good }
        if ms < thresholds.yellowMaxMs { return .moderate }
        if ms < thresholds.orangeMaxMs { return .slow }
        return .poor
    }
}

struct LatencyThresholds: Sendable, Equatable {
    let greenMaxMs: Double
    let yellowMaxMs: Double
    let orangeMaxMs: Double

    static let `default` = LatencyThresholds(
        greenMaxMs: 500,
        yellowMaxMs: 1000,
        orangeMaxMs: 2000
    )
}

enum LatencyProbeTarget: String, CaseIterable, Identifiable, Sendable {
    case cloudflare     // https://1.1.1.1/
    case googleGenerate // https://www.gstatic.com/generate_204

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .cloudflare: return URL(string: "https://1.1.1.1/cdn-cgi/trace")!
        case .googleGenerate: return URL(string: "https://www.gstatic.com/generate_204")!
        }
    }

    var label: String {
        switch self {
        case .cloudflare:     String(localized: "Cloudflare (1.1.1.1)")
        case .googleGenerate: String(localized: "Google (gstatic.com)")
        }
    }
}

enum LatencyInterval: Int, CaseIterable, Identifiable, Sendable {
    case s60 = 60
    case s300 = 300
    case s600 = 600

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .s60:  String(localized: "Every minute")
        case .s300: String(localized: "Every 5 minutes")
        case .s600: String(localized: "Every 10 minutes")
        }
    }
}
