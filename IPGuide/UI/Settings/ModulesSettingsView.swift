import AppKit
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
                        // AppKit TextField via NSViewRepresentable. SwiftUI's
                        // `@FocusState` on macOS doesn't fire for clicks on
                        // non-focusable areas (Section headers, Picker popups,
                        // window chrome, empty space), so the "clear on blur"
                        // rule silently failed. NSTextField's
                        // `controlTextDidEndEditing` delegate fires reliably
                        // for every blur path — tab, Enter, clicking any
                        // other element, window dismiss.
                        CustomURLField(
                            text: $settings.throughputCustomURL,
                            onCommit: normalizeCustomURL
                        )
                        .frame(maxWidth: .infinity, minHeight: 22)
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

    /// Normalize the custom URL field on blur:
    /// - trim whitespace
    /// - if what's left parses as an `https://` URL, save the trimmed version
    /// - otherwise (empty, garbage, wrong scheme) clear the field so the user
    ///   immediately sees that their input didn't stick. The probe surfaces
    ///   a failure state rather than silently substituting a preset.
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

/// Thin AppKit bridge around `NSTextField` so we get a real
/// `controlTextDidEndEditing` delegate callback on every blur path.
///
/// SwiftUI's `TextField` + `@FocusState` on macOS only fires on blur when
/// focus transitions to another focusable element. Clicks on Picker
/// popups, Section headers, the window title bar, or empty form space
/// leave the TextField focused — so the "clear invalid URL on blur" rule
/// silently fails. AppKit's NSTextField resigns first responder and
/// notifies its delegate for all of those cases.
private struct CustomURLField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.sendsActionOnEndEditing = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var onCommit: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // Fires on tab-out, Enter, clicking any other element, window
            // losing focus, view removal — every blur path we care about.
            onCommit()
        }
    }
}
