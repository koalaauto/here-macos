import Foundation

/// One recorded transition of the egress IP. Stored as a chronological list
/// in `IPHistoryService` and persisted to disk.
struct IPChangeEvent: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let at: Date
    let ip: String
    let countryCode: String    // uppercase ISO-alpha-2
    let countryName: String
    let city: String
    let asnLabel: String

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        ip: String,
        countryCode: String,
        countryName: String,
        city: String,
        asnLabel: String
    ) {
        self.id = id
        self.at = at
        self.ip = ip
        self.countryCode = countryCode
        self.countryName = countryName
        self.city = city
        self.asnLabel = asnLabel
    }

    static func from(_ model: IPDataModel) -> IPChangeEvent {
        IPChangeEvent(
            ip: model.ip,
            countryCode: model.countryAlpha2,
            countryName: model.location.country,
            city: model.location.city,
            asnLabel: model.asnLabel
        )
    }
}
