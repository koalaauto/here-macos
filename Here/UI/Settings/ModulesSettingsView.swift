import SwiftUI

struct ModulesSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @FocusState private var latencyURLFocused: Bool
    @FocusState private var throughputURLFocused: Bool

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
                Text(String(localized: "Drag to reorder cards in the popover."))
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
                .onChange(of: settings.latencyProbeTarget) { _, _ in
                    trimLatencyCustomURL()
                    latencyURLFocused = false
                }

                if settings.latencyProbeTarget == .custom {
                    URLEntryRow(
                        label: String(localized: "URL"),
                        text: $settings.latencyCustomURL,
                        isValid: settings.latencyTargetURL != nil,
                        focusBinding: $latencyURLFocused,
                        onCommit: trimLatencyCustomURL
                    )
                    .disabled(!settings.latencyEnabled)
                }

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
                .help(String(localized: "Turn the menu bar pill border red when a probe times out or exceeds 600 ms."))
            }

            Section {
                Picker(String(localized: "Source"), selection: $settings.throughputEndpoint) {
                    ForEach(ThroughputEndpoint.allCases) { endpoint in
                        Text(endpoint.label).tag(endpoint)
                    }
                }
                .onChange(of: settings.throughputEndpoint) { _, _ in
                    trimThroughputCustomURL()
                    throughputURLFocused = false
                }

                if settings.throughputEndpoint == .custom {
                    URLEntryRow(
                        label: String(localized: "URL"),
                        text: $settings.throughputCustomURL,
                        isValid: settings.throughputTargetURL != nil,
                        focusBinding: $throughputURLFocused,
                        onCommit: trimThroughputCustomURL
                    )
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
        .simultaneousGesture(
            TapGesture()
                .onEnded { _ in
                    trimLatencyCustomURL()
                    trimThroughputCustomURL()
                    latencyURLFocused = false
                    throughputURLFocused = false
                }
        )
    }

    private func trimLatencyCustomURL() {
        let trimmed = settings.latencyCustomURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.latencyCustomURL != trimmed {
            settings.latencyCustomURL = trimmed
        }
    }

    private func trimThroughputCustomURL() {
        let trimmed = settings.throughputCustomURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.throughputCustomURL != trimmed {
            settings.throughputCustomURL = trimmed
        }
    }

    private func throughputFooterText() -> String {
        switch settings.throughputEndpoint {
        case .cachefly:
            return String(localized: "100 MB from Cachefly CDN. Default.")
        case .cloudflare:
            return String(localized: "100 MB from speed.cloudflare.com. Sometimes blocked.")
        case .custom:
            return String(localized: "Any HTTP or HTTPS URL. 10 MB or larger works best.")
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

/// Reusable Custom-URL row used by both the Latency and Throughput
/// settings sections. Layout: standard `LabeledContent` with the
/// label on the left and an HStack on the right that puts a tiny
/// validation badge before the field. Putting the badge to the
/// **left** of the field (instead of overlaying it on the trailing
/// edge) is what keeps the bezel's right edge flush with the
/// pickers / toggles above and below — and avoids the badge
/// sitting on top of long URLs.
private struct URLEntryRow: View {
    let label: String
    @Binding var text: String
    let isValid: Bool
    var focusBinding: FocusState<Bool>.Binding
    var onCommit: () -> Void = {}

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                // Hide the validation badge while the field is being
                // edited (kept in the layout via `opacity(0)` so the
                // textfield doesn't jump). The status reappears after
                // the user blurs — matches the "only validate on
                // unfocus" expectation, no jittery live feedback.
                ValidationBadge(isValid: isValid)
                    .opacity(focusBinding.wrappedValue ? 0 : 1)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .focused(focusBinding)
                    .frame(maxWidth: .infinity)
                    .onSubmit {
                        onCommit()
                        focusBinding.wrappedValue = false
                    }
                    .onExitCommand {
                        focusBinding.wrappedValue = false
                    }
            }
        } label: {
            Text(label)
        }
        // Auto-focus when the row appears so the user can start
        // typing immediately after switching to `.custom` (or
        // re-opening Settings).
        .onAppear {
            focusBinding.wrappedValue = true
        }
    }
}

private struct ValidationBadge: View {
    let isValid: Bool

    var body: some View {
        Image(systemName: isValid
              ? "checkmark.circle.fill"
              : "exclamationmark.triangle.fill")
            .foregroundStyle(isValid ? .green : .yellow)
            .imageScale(.medium)
            .help(isValid
                  ? String(localized: "Valid URL")
                  : String(localized: "Invalid URL"))
            .accessibilityLabel(isValid
                                ? String(localized: "Valid URL")
                                : String(localized: "Invalid URL"))
    }
}
