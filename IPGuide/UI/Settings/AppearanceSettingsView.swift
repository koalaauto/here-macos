import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section(String(localized: "What to show")) {
                Picker(String(localized: "Status bar shows"), selection: $settings.showMode) {
                    ForEach(ShowMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section(String(localized: "Country style")) {
                Picker(String(localized: "Country display"), selection: $settings.countryStyle) {
                    ForEach(CountryStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(settings.showMode == .regionOnly)
            }
        }
        .formStyle(.grouped)
    }
}
