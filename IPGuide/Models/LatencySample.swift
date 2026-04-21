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
    case poor           // >= orange
    case failed         // timeout / error

    static func classify(_ sample: LatencySample?, thresholds: LatencyThresholds) -> LatencyBucket {
        guard let sample else { return .empty }
        guard let ms = sample.latencyMs else { return .failed }
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
        greenMaxMs: 150,
        yellowMaxMs: 500,
        orangeMaxMs: 1000
    )
}

enum LatencyProbeTarget: String, CaseIterable, Identifiable, Sendable {
    case cloudflare     // https://1.1.1.1/
    case googleGenerate // https://www.gstatic.com/generate_204
    case ipGuide        // https://ip.guide/

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .cloudflare: return URL(string: "https://1.1.1.1/cdn-cgi/trace")!
        case .googleGenerate: return URL(string: "https://www.gstatic.com/generate_204")!
        case .ipGuide: return URL(string: "https://ip.guide/")!
        }
    }

    var label: String {
        switch self {
        case .cloudflare:     String(localized: "Cloudflare (1.1.1.1)")
        case .googleGenerate: String(localized: "Google (gstatic.com)")
        case .ipGuide:        String(localized: "ip.guide")
        }
    }
}

enum LatencyInterval: Int, CaseIterable, Identifiable, Sendable {
    case s10 = 10
    case s30 = 30
    case s60 = 60
    case s120 = 120
    case s300 = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .s10:  String(localized: "Every 10 seconds")
        case .s30:  String(localized: "Every 30 seconds")
        case .s60:  String(localized: "Every minute")
        case .s120: String(localized: "Every 2 minutes")
        case .s300: String(localized: "Every 5 minutes")
        }
    }
}
