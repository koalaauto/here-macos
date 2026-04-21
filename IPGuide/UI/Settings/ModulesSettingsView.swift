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
                    Text(verbatim: "15").tag(15)
                    Text(verbatim: "30").tag(30)
                    Text(verbatim: "45").tag(45)
                    Text(verbatim: "60").tag(60)
                    Text(verbatim: "90").tag(90)
                    Text(verbatim: "120").tag(120)
                }
                .disabled(!settings.latencyEnabled)
            }
        }
        .formStyle(.grouped)
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
