import SwiftUI

/// Small SwiftUI view shown in a borderless NSPanel while the
/// in-app update installer runs. Phases drive what's rendered:
/// download progress bar → "Mounting…" / "Installing…" /
/// "Restarting…" labels → on success the host quits before the
/// last frame ever paints.
@MainActor
@Observable
final class UpdateProgressModel {
    var phase: UpdateInstaller.Phase = .downloading(progress: 0)
}

struct UpdateProgressView: View {
    let model: UpdateProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
            }

            switch model.phase {
            case .downloading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                // Plain interpolation, not String(localized:) — `%`
                // and digits don't translate, and the auto-generated
                // localization key for this would be `%lld%%` which
                // doesn't match anything in the strings file anyway.
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .mounting, .copying, .relaunching:
                ProgressView()
                    .progressViewStyle(.linear)
            case .failed(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var title: String {
        switch model.phase {
        case .downloading:  String(localized: "Downloading update…")
        case .mounting:     String(localized: "Mounting…")
        case .copying:      String(localized: "Installing…")
        case .relaunching:  String(localized: "Restarting Here…")
        case .failed:       String(localized: "Update failed")
        }
    }

    private var icon: String {
        switch model.phase {
        case .downloading:  "arrow.down.circle"
        case .mounting:     "externaldrive"
        case .copying:      "shippingbox"
        case .relaunching:  "arrow.triangle.2.circlepath"
        case .failed:       "exclamationmark.triangle"
        }
    }
}
