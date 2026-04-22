import SwiftUI

struct MetaFooter: View {
    let state: IPState
    let lastFetchedAt: Date?
    let onRefresh: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            leadingLabel
            Spacer()
            RefreshButton(isLoading: state.isLoading, action: onRefresh)
                .buttonStyle(.borderless)
                .pointerStyle(.link)
            Button(action: handleSettingsTap) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .keyboardShortcut(",", modifiers: [.command])
            .help(String(localized: "Settings"))
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .keyboardShortcut("q", modifiers: [.command])
            .help(String(localized: "Quit Here"))
        }
    }

    @ViewBuilder
    private var leadingLabel: some View {
        if let fetchedAt = lastFetchedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(String(localized: "Updated \(relativeString(fetchedAt, relativeTo: context.date))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func handleSettingsTap() {
        NotificationCenter.default.post(name: .ipGuidePopoverCloseRequested, object: nil)
        openSettings()
    }

    private func relativeString(_ date: Date, relativeTo reference: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}
