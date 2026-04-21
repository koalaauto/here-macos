import Foundation

enum PopoverModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case location
    case latency
    case history
    case throughput

    var id: String { rawValue }

    var label: String {
        switch self {
        case .location:   String(localized: "Location")
        case .latency:    String(localized: "Latency")
        case .history:    String(localized: "History")
        case .throughput: String(localized: "Throughput")
        }
    }

    var systemImage: String {
        switch self {
        case .location:   "map"
        case .latency:    "waveform.path.ecg"
        case .history:    "clock.arrow.circlepath"
        case .throughput: "speedometer"
        }
    }

    static let defaultOrder: [PopoverModule] = [.location, .latency, .history, .throughput]
}
