import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            AppIconView()
                .frame(width: 88, height: 88)

            Text("Here")
                .font(.title2)
                .fontWeight(.semibold)

            Text(versionString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                if let url = URL(string: "https://github.com/bikekoala/here-macos") {
                    openURL(url)
                }
            } label: {
                Label(String(localized: "Source on GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.link)
            .pointerStyle(.link)
            .font(.caption)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// The shipped app-icon artwork. Renders the raster `AppIconArtwork`
/// image set (the same source PNG the `AppIcon` app-icon set is
/// generated from) rather than `NSImage(named:
/// NSImage.applicationIconName)`, which returns a padded
/// icon-template that visibly shrinks the artwork inside its frame.
private struct AppIconView: View {
    var body: some View {
        Image("AppIconArtwork")
            .resizable()
            .scaledToFit()
    }
}
