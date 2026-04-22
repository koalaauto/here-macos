import Foundation
import Testing

@testable import Here

// Anchor class for locating the test bundle's resources (Xcode test target).
private final class TestBundleAnchor {}

@Suite("IPDataModel decoding")
struct IPDataModelTests {

    @Test func decodesSampleResponse() throws {
        let model = try decodedFixture()
        #expect(model.ip == "38.175.104.131")
        #expect(model.network.cidr == "38.175.104.0/24")
        #expect(model.network.autonomousSystem.asn == 917)
        #expect(model.network.autonomousSystem.country == "US")
        #expect(model.location.city == "San Jose")
        #expect(model.location.country == "United States")
        #expect(model.location.timezone == "America/Los_Angeles")
    }

    @Test func derivedCountryAlpha2IsUppercase() throws {
        let model = try decodedFixture()
        #expect(model.countryAlpha2 == "US")
    }

    @Test func derivedCoordinateMatches() throws {
        let model = try decodedFixture()
        #expect(abs(model.coordinate.latitude - 37.2379) < 0.0001)
        #expect(abs(model.coordinate.longitude - (-121.7946)) < 0.0001)
    }

    @Test func asnLabelStripsSuffix() throws {
        let model = try decodedFixture()
        #expect(model.asnLabel == "AS917 · MISAKA")
    }

    private func decodedFixture() throws -> IPDataModel {
        let bundle = Bundle(for: TestBundleAnchor.self)
        let url = try #require(
            bundle.url(forResource: "sample_response", withExtension: "json")
            ?? bundle.url(forResource: "sample_response", withExtension: "json", subdirectory: "Fixtures")
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(IPDataModel.self, from: data)
    }
}
