import Foundation

enum ShowMode: String, CaseIterable, Identifiable, Sendable {
    case countryOnly
    case regionOnly
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .countryOnly: String(localized: "Country only")
        case .regionOnly: String(localized: "Region only")
        case .both: String(localized: "Country and region")
        }
    }
}

enum CountryStyle: String, CaseIterable, Identifiable, Sendable {
    case text
    case flag

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: String(localized: "Text")
        case .flag: String(localized: "Flag")
        }
    }
}
