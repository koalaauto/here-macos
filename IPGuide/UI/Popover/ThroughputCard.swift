import SwiftUI

/// On-demand download + upload speed test card.
///
/// Layout:
/// ```
/// ┌─────────────────────────────────────────┐
/// │ THROUGHPUT                 tested 3m ago │
/// │                                          │
/// │   ↓ 85.2        ↑ 12.4                   │
/// │   Mbps          Mbps                     │
/// │   ═══════       ═══════                  │
/// │                                          │
/// │                              [ ↻ Test ]  │
/// └─────────────────────────────────────────┘
/// ```
/// During a test, the active direction's numbers animate up from 0 and its
/// progress bar linearly fills over `estimatedDuration` (not byte-accurate —
/// the actual transfer may finish sooner/later; the final number is the
/// measured ground truth that replaces the animation).
struct ThroughputCard: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var status: ThroughputStatus = .idle(lastResult: nil)

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                header
                speedRow
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

    // MARK: Speed row

    private var speedRow: some View {
        HStack(alignment: .top, spacing: 20) {
            speedBlock(
                label: String(localized: "↓"),
                direction: .download
            )
            speedBlock(
                label: String(localized: "↑"),
                direction: .upload
            )
        }
    }

    private func speedBlock(label: String, direction: ThroughputStatus.Direction) -> some View {
        let (numericText, progress, isActive) = stateForDirection(direction)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                Task { await environment.throughputService.runTest() }
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
            .disabled(status.isRunning)
        }
    }

    // MARK: Helpers

    /// Derive the display string + progress fraction + "is this the direction
    /// currently being measured?" for one arrow.
    ///
    /// The contract while probing: show `"…"` for any direction whose fresh
    /// value hasn't landed yet. Stale values from a previous run are NOT
    /// shown during a new test — that's confusing UX ("wait, is that the
    /// new number already?"). The user sees each block fill in as its
    /// measurement completes.
    private func stateForDirection(
        _ direction: ThroughputStatus.Direction
    ) -> (text: String, progress: Double, isActive: Bool) {
        switch status {
        case .idle(let last), .failed(_, let last):
            let mbps = directionValue(from: last, direction: direction)
            return (format(mbps), mbps == nil ? 0 : 1, false)

        case .probing(let phase, let startedAt, let estDur, let downloadSoFar):
            if phase == direction {
                // Active direction: linear time-based pseudo-progress. The
                // actual transfer's completion beats the animation on fast
                // connections — that's fine because we immediately advance
                // the state and the bar snaps to 100% in the "just completed"
                // branch below.
                let elapsed = Date().timeIntervalSince(startedAt)
                let progress = min(1, max(0, elapsed / estDur))
                return ("…", progress, true)
            }
            if direction == .download, phase == .upload {
                // Download phase finished; `downloadSoFar` holds the just-
                // measured value. Bar is 100%, number is the fresh reading.
                return (format(downloadSoFar), 1.0, false)
            }
            // Upload block during download phase: not started yet. Blank.
            return ("…", 0, false)
        }
    }

    private func directionValue(
        from result: ThroughputResult?,
        direction: ThroughputStatus.Direction
    ) -> Double? {
        guard let result else { return nil }
        return direction == .download ? result.downloadMbps : result.uploadMbps
    }

    private func format(_ mbps: Double?) -> String {
        guard let mbps else { return "—" }
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

    // MARK: Observation

    private func observe() async {
        for await next in environment.throughputService.stream() {
            withAnimation(.easeInOut(duration: 0.2)) {
                status = next
            }
        }
    }
}
