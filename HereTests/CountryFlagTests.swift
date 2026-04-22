import Testing

@testable import Here

@Suite("CountryFlag")
struct CountryFlagTests {

    @Test func rendersKnownCodes() {
        #expect(CountryFlag.emoji(alpha2: "US") == "🇺🇸")
        #expect(CountryFlag.emoji(alpha2: "DE") == "🇩🇪")
        #expect(CountryFlag.emoji(alpha2: "JP") == "🇯🇵")
    }

    @Test func handlesLowercase() {
        #expect(CountryFlag.emoji(alpha2: "us") == "🇺🇸")
    }

    @Test func rejectsInvalidLength() {
        #expect(CountryFlag.emoji(alpha2: "USA") == nil)
        #expect(CountryFlag.emoji(alpha2: "") == nil)
        #expect(CountryFlag.emoji(alpha2: "U") == nil)
    }

    @Test func rejectsNonLetters() {
        #expect(CountryFlag.emoji(alpha2: "U1") == nil)
        #expect(CountryFlag.emoji(alpha2: "??") == nil)
    }
}
