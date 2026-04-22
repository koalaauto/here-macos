import Testing

@testable import Here

struct FakeGeocoder: ReverseGeocoding {
    let result: String?
    func lookup(latitude: Double, longitude: Double) async -> String? { result }
}

@Suite("RegionMapper")
struct RegionMapperTests {
    private func sampleModel(city: String = "San Jose", country: String = "US",
                             countryName: String = "United States") -> IPDataModel {
        IPDataModel(
            ip: "1.2.3.4",
            network: .init(
                cidr: "1.2.3.0/24",
                hosts: .init(start: "1.2.3.1", end: "1.2.3.254"),
                autonomousSystem: .init(
                    asn: 1, name: "X", organization: "X",
                    country: country, rir: "ARIN"
                )
            ),
            location: .init(
                city: city, country: countryName,
                timezone: "UTC", latitude: 0, longitude: 0
            )
        )
    }

    @Test func passesThroughIsoCode() async {
        let mapper = RegionMapper(geocoder: FakeGeocoder(result: "CA"))
        let code = await mapper.regionCode(for: sampleModel())
        #expect(code == "CA")
    }

    @Test func mapsFullNameViaTable() async {
        let mapper = RegionMapper(geocoder: FakeGeocoder(result: "California"))
        let code = await mapper.regionCode(for: sampleModel())
        #expect(code == "CA")
    }

    @Test func fallsBackToCityInitialsWhenGeocoderFails() async {
        let mapper = RegionMapper(geocoder: FakeGeocoder(result: nil))
        let code = await mapper.regionCode(for: sampleModel(city: "San Jose"))
        #expect(code == "SJ")
    }

    @Test func usesWordInitialsForMultiWordCities() {
        #expect(RegionMapper.cityInitials("San Jose") == "SJ")
        #expect(RegionMapper.cityInitials("New York") == "NY")
        #expect(RegionMapper.cityInitials("Los Angeles") == "LA")
        #expect(RegionMapper.cityInitials("São Paulo") == "SP")
    }

    @Test func usesFirstTwoLettersForSingleWordCities() {
        #expect(RegionMapper.cityInitials("Beijing") == "BE")
        #expect(RegionMapper.cityInitials("Zürich") == "ZU")
    }

    @Test func cachesResult() async {
        let mapper = RegionMapper(geocoder: FakeGeocoder(result: "WA"))
        let first = await mapper.regionCode(for: sampleModel(city: "Seattle"))
        let second = await mapper.regionCode(for: sampleModel(city: "Seattle"))
        #expect(first == "WA")
        #expect(second == "WA")
    }
}
