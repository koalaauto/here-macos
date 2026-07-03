import Foundation

struct LatencySample: Sendable, Equatable, Identifiable {
    let id: UUID
    let at: Date
    /// Measured round-trip in milliseconds. `nil` means the probe timed out or errored.
    let latencyMs: Double?
    /// `true` when the probe loop ticked but had no target to hit
    /// (e.g. `.custom` selected with an empty/invalid URL). Visually
    /// gray, excluded from stats — distinct from a real timeout/error
    /// (`latencyMs == nil && !wasSkipped`) which collapses to red.
    let wasSkipped: Bool

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        latencyMs: Double?,
        wasSkipped: Bool = false
    ) {
        self.id = id
        self.at = at
        self.latencyMs = latencyMs
        self.wasSkipped = wasSkipped
    }
}

enum LatencyBucket: Sendable {
    case empty          // never probed, or probe was skipped
    case good           // < greenMaxMs
    case moderate       // green..<yellow
    case slow           // yellow..<orange
    case poor           // >= orange, OR timeout / network error

    static func classify(_ sample: LatencySample?, thresholds: LatencyThresholds) -> LatencyBucket {
        guard let sample else { return .empty }
        if sample.wasSkipped { return .empty }
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
        greenMaxMs: 150,
        yellowMaxMs: 300,
        orangeMaxMs: 600
    )
}

enum LatencyProbeTarget: String, CaseIterable, Identifiable, Sendable {
    case googleGenerate // https://www.gstatic.com/generate_204
    case custom

    var id: String { rawValue }

    /// Preset URL for built-in targets. `nil` for `.custom` — the actual
    /// URL lives in `SettingsStore.latencyCustomURL`.
    var presetURL: URL? {
        switch self {
        case .googleGenerate: return URL(string: "https://www.gstatic.com/generate_204")
        case .custom:         return nil
        }
    }

    var label: String {
        switch self {
        case .googleGenerate: String(localized: "Google (gstatic.com)")
        case .custom:         String(localized: "Custom URL")
        }
    }

    /// Resolve to a concrete `URL`. For `.custom` the supplied string
    /// must be a valid `http://` or `https://` URL — otherwise returns
    /// `nil` and the scheduler will simply skip the probe until the
    /// user fixes it.
    func resolveURL(customURL: String) -> URL? {
        if let preset = presetURL { return preset }
        return URL.fromUserCustomEndpoint(customURL)
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
