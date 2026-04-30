import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @State private var launchAtLoginError: String?
    @State private var checkingForUpdate = false

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
                Picker(
                    String(localized: "Check for updates"),
                    selection: $settings.updateCheckFrequency
                ) {
                    ForEach(UpdateCheckFrequency.allCases) { freq in
                        Text(freq.localizedTitle).tag(freq)
                    }
                }

                LabeledContent(String(localized: "Last checked")) {
                    HStack(spacing: 8) {
                        Text(lastCheckedDescription(settings.lastUpdateCheckAt))
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await runCheckNow() }
                        } label: {
                            if checkingForUpdate {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(String(localized: "Checking…"))
                                }
                            } else {
                                Text(String(localized: "Check now"))
                            }
                        }
                        .disabled(checkingForUpdate)
                    }
                }
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

    private func runCheckNow() async {
        checkingForUpdate = true
        defer { checkingForUpdate = false }
        await environment.updateCoordinator.checkNow()
    }

    private func lastCheckedDescription(_ date: Date?) -> String {
        guard let date else {
            return String(localized: "Never")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
