import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            appIcon
                .frame(width: 72, height: 72)

            Text("IP Guide")
                .font(.title2)
                .fontWeight(.semibold)

            Text(versionString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(String(localized: "Data provided by ip.guide"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button {
                    if let url = URL(string: "https://ip.guide") {
                        openURL(url)
                    }
                } label: {
                    Label("ip.guide", systemImage: "globe")
                }
                .buttonStyle(.link)
                .pointerStyle(.link)

                Button {
                    if let url = URL(string: "https://github.com/bikekoala/ip-info") {
                        openURL(url)
                    }
                } label: {
                    Label(String(localized: "Source on GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.link)
                .pointerStyle(.link)
            }
            .font(.caption)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "globe.americas.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
        }
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
