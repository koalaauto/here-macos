import Foundation

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case m1 = 60
    case m5 = 300
    case m10 = 600
    case m30 = 1800
    case h1 = 3600

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .m1:  String(localized: "Every minute")
        case .m5:  String(localized: "Every 5 minutes")
        case .m10: String(localized: "Every 10 minutes")
        case .m30: String(localized: "Every 30 minutes")
        case .h1:  String(localized: "Every hour")
        }
    }

    static func nearest(to seconds: Int) -> RefreshInterval {
        allCases.min(by: { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) }) ?? .m5
    }
}
