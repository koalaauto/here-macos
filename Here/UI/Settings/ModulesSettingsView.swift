import SwiftUI

struct ModulesSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                ForEach(settings.popoverModuleOrder) { module in
                    moduleRow(for: module, in: settings.popoverModuleOrder)
                }
            } header: {
                Text(String(localized: "Popover module order"))
            } footer: {
                Text(String(localized: "Reorder cards shown below the IP header in the popover."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Latency probe")) {
                Toggle(String(localized: "Enable"), isOn: $settings.latencyEnabled)

                Picker(String(localized: "Target"), selection: $settings.latencyProbeTarget) {
                    ForEach(LatencyProbeTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .disabled(!settings.latencyEnabled)

                Picker(String(localized: "Interval"), selection: $settings.latencyInterval) {
                    ForEach(LatencyInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .disabled(!settings.latencyEnabled)

                Picker(String(localized: "Slots"), selection: $settings.latencySlotCount) {
                    Text(verbatim: "30").tag(30)
                    Text(verbatim: "45").tag(45)
                    Text(verbatim: "60").tag(60)
                }
                .disabled(!settings.latencyEnabled)

                Toggle(
                    String(localized: "Red border on poor latency"),
                    isOn: $settings.widgetLatencyAlert
                )
                .disabled(!settings.latencyEnabled)
                .help(String(localized: "Turn the menu bar pill border red when a probe times out or exceeds 2 s."))
            }

            Section {
                Picker(String(localized: "Source"), selection: $settings.throughputEndpoint) {
                    ForEach(ThroughputEndpoint.allCases) { endpoint in
                        Text(endpoint.label).tag(endpoint)
                    }
                }
                .onChange(of: settings.throughputEndpoint) { _, _ in
                    // Switching away from .custom is a good moment to
                    // normalize — if the user leaves garbage in the field
                    // and flips to another source, don't let it sit there.
                    normalizeCustomURL()
                }

                if settings.throughputEndpoint == .custom {
                    LabeledContent {
                        TextField("", text: $settings.throughputCustomURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)
                            .frame(maxWidth: .infinity)
                            .onSubmit { normalizeCustomURL() }
                    } label: {
                        Text(String(localized: "URL"))
                    }
                }
            } header: {
                Text(String(localized: "Throughput"))
            } footer: {
                Text(throughputFooterText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Normalize the custom URL field: trim whitespace; if what's left is
    /// a valid `https://` URL keep it, otherwise clear. Called from the
    /// couple of places where SwiftUI can reliably trigger us on macOS —
    /// `.onSubmit` (Enter key) and `onChange(of: endpoint)` when the user
    /// switches source. For the "clicked away" case, SwiftUI's
    /// `@FocusState` doesn't fire on clicks onto non-focusable elements,
    /// so that path is covered by the Run Test handler in `ThroughputCard`
    /// which also clears + surfaces a real failure reason.
    private func normalizeCustomURL() {
        let trimmed = settings.throughputCustomURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.scheme?.lowercased() == "https",
           url.host?.isEmpty == false {
            if settings.throughputCustomURL != trimmed {
                settings.throughputCustomURL = trimmed
            }
        } else {
            if !settings.throughputCustomURL.isEmpty {
                settings.throughputCustomURL = ""
            }
        }
    }

    private func throughputFooterText() -> String {
        switch settings.throughputEndpoint {
        case .cachefly:
            return String(localized: "Downloads a 100 MB test file from Cachefly's CDN. Widest global reach; default.")
        case .cloudflare:
            return String(localized: "Downloads 100 MB from speed.cloudflare.com. Blocked on some networks that SNI-filter Cloudflare's speed test host.")
        case .custom:
            return String(localized: "Any HTTPS file works. Larger files (≥ 10 MB) give a more stable reading. Blank or invalid URLs produce an error — no silent fallback.")
        }
    }

    @ViewBuilder
    private func moduleRow(for module: PopoverModule, in order: [PopoverModule]) -> some View {
        @Bindable var settings = settings
        let index = order.firstIndex(of: module) ?? 0
        HStack(spacing: 10) {
            Image(systemName: module.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(module.label)
            Spacer()
            Button {
                move(module, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .disabled(index == 0)
            .help(String(localized: "Move up"))

            Button {
                move(module, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .disabled(index == order.count - 1)
            .help(String(localized: "Move down"))
        }
    }

    private func move(_ module: PopoverModule, by offset: Int) {
        var order = settings.popoverModuleOrder
        guard let current = order.firstIndex(of: module) else { return }
        let target = current + offset
        guard order.indices.contains(target) else { return }
        order.remove(at: current)
        order.insert(module, at: target)
        settings.popoverModuleOrder = order
    }
}
