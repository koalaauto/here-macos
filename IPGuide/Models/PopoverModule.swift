import Foundation

enum PopoverModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case location
    case latency

    var id: String { rawValue }

    var label: String {
        switch self {
        case .location: String(localized: "Location")
        case .latency:  String(localized: "Latency")
        }
    }

    var systemImage: String {
        switch self {
        case .location: "map"
        case .latency:  "waveform.path.ecg"
        }
    }

    static let defaultOrder: [PopoverModule] = [.location, .latency]
}
