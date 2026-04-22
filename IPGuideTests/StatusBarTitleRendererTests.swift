import Testing

@testable import IPGuide

@Suite("StatusBarTitleRenderer")
struct StatusBarTitleRendererTests {

    private func makeInput(
        countryAlpha2: String?,
        regionCode: String?,
        showMode: ShowMode,
        countryStyle: CountryStyle
    ) -> StatusBarTitleRenderer.Input {
        StatusBarTitleRenderer.Input(
            countryAlpha2: countryAlpha2,
            regionCode: regionCode,
            showMode: showMode,
            countryStyle: countryStyle,
            borderTint: .neutral,
            flagMono: true
        )
    }

    @Test func bothText() {
        let s = StatusBarTitleRenderer.plain(makeInput(
            countryAlpha2: "US", regionCode: "CA", showMode: .both, countryStyle: .text
        ))
        #expect(s == "US CA")
    }

    @Test func bothFlag() {
        let s = StatusBarTitleRenderer.plain(makeInput(
            countryAlpha2: "US", regionCode: "CA", showMode: .both, countryStyle: .flag
        ))
        #expect(s == "🇺🇸 CA")
    }

    @Test func countryOnlyText() {
        let s = StatusBarTitleRenderer.plain(makeInput(
            countryAlpha2: "DE", regionCode: "BE", showMode: .countryOnly, countryStyle: .text
        ))
        #expect(s == "DE")
    }

    @Test func regionOnly() {
        let s = StatusBarTitleRenderer.plain(makeInput(
            countryAlpha2: "US", regionCode: "NY", showMode: .regionOnly, countryStyle: .flag
        ))
        #expect(s == "NY")
    }

    @Test func missingCountryFallsBackToQuestionMarks() {
        let s = StatusBarTitleRenderer.plain(makeInput(
            countryAlpha2: nil, regionCode: "CA", showMode: .countryOnly, countryStyle: .flag
        ))
        #expect(s == "??")
    }

    @Test func missingRegionFallsBackToQuestionMarks() {
        let s = StatusBarTitleRenderer.plain(makeInput(
            countryAlpha2: "US", regionCode: nil, showMode: .both, countryStyle: .text
        ))
        #expect(s == "US ??")
    }
}
