import SwiftUI

/// Colors and symbol shared between `scripts/generate_icon.swift` (which builds
/// the real app-icon PNGs) and this in-app About view. Keep them in sync when
/// updating the icon design.
private enum IconDesign {
    static let gradientTop = Color(red: 0.22, green: 0.67, blue: 0.82)
    static let gradientBottom = Color(red: 0.09, green: 0.32, blue: 0.66)
    static let symbolName = "globe.americas.fill"
    static let cornerRadiusRatio: CGFloat = 0.22
    static let symbolSizeRatio: CGFloat = 0.62
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @State private var checking = false

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 14) {
            VStack(spacing: 8) {
                AppIconView()
                    .frame(width: 80, height: 80)

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
                    Label(
                        String(localized: "Source on GitHub"),
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
                .buttonStyle(.link)
                .pointerStyle(.link)
                .font(.caption)
            }

            Divider()
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(localized: "Check for updates"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Picker("", selection: $settings.updateCheckFrequency) {
                        ForEach(UpdateCheckFrequency.allCases) { freq in
                            Text(freq.localizedTitle).tag(freq)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await runCheckNow() }
                    } label: {
                        if checking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(String(localized: "Checking…"))
                            }
                        } else {
                            Text(String(localized: "Check now"))
                        }
                    }
                    .disabled(checking)
                    .controlSize(.small)

                    Spacer()

                    Text(lastCheckedDescription(settings.lastUpdateCheckAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func runCheckNow() async {
        checking = true
        defer { checking = false }
        await environment.updateCoordinator.checkNow()
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func lastCheckedDescription(_ date: Date?) -> String {
        guard let date else {
            return String(localized: "Never checked")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return String(localized: "Last checked \(relative)")
    }
}

/// SwiftUI-rendered stand-in for the app icon — avoids the padded "icon template"
/// that `NSImage(named: NSImage.applicationIconName)` returns, which makes the
/// artwork shrink inside its frame.
private struct AppIconView: View {
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: size * IconDesign.cornerRadiusRatio, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [IconDesign.gradientTop, IconDesign.gradientBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Image(systemName: IconDesign.symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white, .white.opacity(0.55))
                    .frame(width: size * IconDesign.symbolSizeRatio,
                           height: size * IconDesign.symbolSizeRatio)
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
