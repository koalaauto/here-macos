import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @State private var launchAtLoginError: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle(String(localized: "Launch at login"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { updateLaunchAtLogin($0) }
                ))

                if let err = launchAtLoginError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(String(localized: "Refresh"), selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                Toggle(
                    String(localized: "Auto-refresh on network change"),
                    isOn: $settings.refreshOnNetworkChange
                )
            } footer: {
                Text(String(localized: "Also refresh when WiFi hops, the system proxy toggles, or the network path otherwise shifts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            settings.launchAtLogin = environment.launchAtLogin.isEnabled
        }
    }

    private func updateLaunchAtLogin(_ newValue: Bool) {
        do {
            try environment.launchAtLogin.setEnabled(newValue)
            settings.launchAtLogin = newValue
            launchAtLoginError = nil
        } catch {
            settings.launchAtLogin = environment.launchAtLogin.isEnabled
            launchAtLoginError = (error as NSError).localizedDescription
            Log.launch.error("Toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
