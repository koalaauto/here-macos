import SwiftUI

struct IPHeroView: View {
    let model: IPDataModel
    let regionCode: String?
    let fetchedAt: Date?

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                flagView
                Text(headerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let fetchedAt {
                    StaleBadge(fetchedAt: fetchedAt, threshold: 60 * 60)
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline) {
                Text(model.ip)
                    .font(.system(.title, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: copyIP) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(String(localized: "Copy IP address"))
            }
        }
    }

    private var headerText: String {
        "\(model.location.country) · \(model.location.city)"
    }

    @ViewBuilder
    private var flagView: some View {
        Group {
            if let nsImage = NSImage(named: "flag_\(model.countryAlpha2)") {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            } else if let emoji = CountryFlag.emoji(alpha2: model.countryAlpha2) {
                Text(emoji).font(.title2)
            }
        }
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onTapGesture {
            if let url = URL(string: "https://ip.guide/") {
                openURL(url)
            }
        }
        .help(String(localized: "Open ip.guide in browser"))
    }

    private func copyIP() {
        Clipboard.copy(model.ip)
        withAnimation(.easeIn(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}
