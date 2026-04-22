import SwiftUI

struct CopyableRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var copyable: Bool = true

    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if copyable {
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .opacity(hovering || copied ? 1 : 0)
                .help(String(localized: "Copy"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func copy() {
        Clipboard.copy(value)
        withAnimation(.easeIn(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}
