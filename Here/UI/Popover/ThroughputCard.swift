import SwiftUI

/// On-demand download speed test card.
///
/// Layout:
/// ```
/// ┌─────────────────────────────────────────┐
/// │ THROUGHPUT               Tested 3m ago   │
/// │                                          │
/// │   ↓ 85.2 Mbps                            │
/// │   ═══════                                │
/// │                             [ ↻ Retest ] │
/// └─────────────────────────────────────────┘
/// ```
/// While a test is running, the number blanks to "…" and ticks upward
/// with the rolling Mbps estimate from `ThroughputService` (`liveMbps` on
/// the `.probing` state). The progress bar reflects real transfer progress
/// (bytes received / Content-Length) — when it hits 1.0 the transfer has
/// genuinely finished. The final Mbps replaces the rolling value on
/// completion.
///
/// Source selection (Cachefly default / Cloudflare / Custom URL) lives in
/// Settings → Modules → Throughput.
struct ThroughputCard: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings

    @State private var status: ThroughputStatus = .idle(lastResult: nil)

    private static let invalidCustomURLMessage = String(
        localized: "Custom URL isn't a valid https:// URL."
    )

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                header
                speedBlock
                footer
            }
        }
        .task { await observe() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Throughput"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if case .failed(let reason, _) = status {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            } else if let result = status.lastResult {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(relativeTime(from: result.testedAt, to: context.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Speed block

    private var speedBlock: some View {
        let (numericText, progress, isActive) = displayState()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("↓")
                    .foregroundStyle(isActive ? .primary : .secondary)
                Text(numericText)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(String(localized: "Mbps"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(.title3, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(isActive ? Color.accentColor : Color.green.opacity(0.55))
                        .frame(width: max(0, geo.size.width * progress))
                        .animation(.linear(duration: isActive ? 0.1 : 0.4), value: progress)
                }
            }
            .frame(height: 3)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                handleRunTap()
            } label: {
                if status.isRunning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Testing…")).font(.caption)
                    }
                } else {
                    Label(
                        status.lastResult == nil
                            ? String(localized: "Run test")
                            : String(localized: "Retest"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerStyle(.link)
            .disabled(status.isRunning)
        }
    }

    // MARK: Helpers

    /// Derive the display tuple for the current status.
    ///
    /// `.idle` / `.failed`  → last known Mbps (or "—"), bar full or empty.
    /// `.probing`           → "…" until the first live reading lands, then
    ///                        the rolling Mbps number; bar tracks real
    ///                        transfer progress.
    private func displayState() -> (text: String, progress: Double, isActive: Bool) {
        switch status {
        case .idle(let last), .failed(_, let last):
            let mbps = last?.downloadMbps
            let text: String
            if let mbps {
                text = format(mbps)
            } else {
                text = "—"
            }
            return (text, mbps == nil ? 0 : 1, false)

        case .probing(let liveMbps, let liveProgress):
            let text: String
            if let live = liveMbps {
                text = format(live)
            } else {
                text = "…"
            }
            return (text, liveProgress, true)
        }
    }

    /// URL for the currently-selected source. Returns `nil` only when the
    /// user is on `.custom` and their URL isn't a valid `https://` URL —
    /// we deliberately do NOT silently substitute a preset, so invalid
    /// input surfaces as a real failure rather than a ghost test against
    /// a different host.
    private func resolvedURL() -> URL? {
        switch settings.throughputEndpoint {
        case .cachefly, .cloudflare:
            return settings.throughputEndpoint.presetURL
        case .custom:
            let trimmed = settings.throughputCustomURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed),
                  url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false else {
                return nil
            }
            return url
        }
    }

    /// Dispatch a Run Test click. If the user is on `.custom` and the
    /// field holds something that isn't a usable URL, clear the field
    /// (matches the on-blur "clear invalid input" rule) and surface a
    /// failure state instead of running the probe against a substitute.
    private func handleRunTap() {
        if let url = resolvedURL() {
            Task { await environment.throughputService.runTest(url: url) }
            return
        }
        if settings.throughputEndpoint == .custom,
           !settings.throughputCustomURL.isEmpty {
            settings.throughputCustomURL = ""
        }
        Task {
            await environment.throughputService.reportLocalFailure(
                reason: Self.invalidCustomURLMessage
            )
        }
    }

    private func format(_ mbps: Double) -> String {
        if mbps >= 100 { return String(format: "%.0f", mbps) }
        return String(format: "%.1f", mbps)
    }

    private func relativeTime(from past: Date, to now: Date) -> String {
        let secs = Int(now.timeIntervalSince(past))
        if secs < 60 {
            return String(localized: "Tested just now")
        }
        if secs < 3600 {
            return String(format: String(localized: "Tested %dm ago"), secs / 60)
        }
        if secs < 86_400 {
            return String(format: String(localized: "Tested %dh ago"), secs / 3600)
        }
        return String(format: String(localized: "Tested %dd ago"), secs / 86_400)
    }

    private func observe() async {
        for await next in environment.throughputService.stream() {
            withAnimation(.easeInOut(duration: 0.2)) {
                status = next
            }
        }
    }
}
