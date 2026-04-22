import SwiftUI

struct LatencyCard: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings

    @State private var samples: [LatencySample] = []
    @State private var hoveredIndex: Int?

    private let thresholds = LatencyThresholds.default

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 8) {
                header
                bar
            }
        }
        .task { await observe() }
    }

    // MARK: Header (single-line, shared "ms")

    private var header: some View {
        HStack(spacing: 10) {
            Text(String(localized: "Latency"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer(minLength: 4)

            statPair(label: String(localized: "last"), value: current, bold: true)
            separator
            statPair(label: String(localized: "avg"), value: average)
            separator
            statPair(label: String(localized: "max"), value: maxValue)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func statPair(label: String, value: String, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(bold ? .semibold : .regular)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    // MARK: Bar with instant custom tooltip

    private var bar: some View {
        GeometryReader { geo in
            let slotCount = settings.latencySlotCount
            let spacing: CGFloat = 2
            let cellWidth = max(1, (geo.size.width - spacing * CGFloat(slotCount - 1)) / CGFloat(slotCount))
            let slots = paddedSlots(count: slotCount)

            HStack(spacing: spacing) {
                ForEach(slots, id: \.position) { slot in
                    cell(for: slot)
                        .frame(width: cellWidth)
                }
            }
            .overlay(alignment: .topLeading) {
                if let idx = hoveredIndex,
                   let slot = slots.first(where: { $0.position == idx }),
                   slot.sample != nil {
                    instantTooltip(
                        text: tooltipText(for: slot),
                        cellCenterX: CGFloat(idx) * (cellWidth + spacing) + cellWidth / 2,
                        containerWidth: geo.size.width
                    )
                }
            }
        }
        .frame(height: 22)
    }

    private func cell(for slot: Slot) -> some View {
        let bucket = LatencyBucket.classify(slot.sample, thresholds: thresholds)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color(for: bucket))
            .opacity(hoveredIndex == nil || hoveredIndex == slot.position ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.08), value: hoveredIndex)
            .onHover { hovering in
                if hovering {
                    hoveredIndex = slot.position
                } else if hoveredIndex == slot.position {
                    hoveredIndex = nil
                }
            }
    }

    /// Renders a small label above the hovered cell. Appears on the first
    /// `onHover` event — no system delay — and is clamped to stay inside the
    /// card horizontally.
    private func instantTooltip(text: String, cellCenterX: CGFloat, containerWidth: CGFloat) -> some View {
        // Measure the tooltip so we can center it over the cell.
        let approxWidth: CGFloat = CGFloat(text.count) * 6.5 + 14
        let halfWidth = approxWidth / 2
        let minX = halfWidth
        let maxX = max(halfWidth, containerWidth - halfWidth)
        let x = min(max(cellCenterX, minX), maxX)

        return Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            )
            .fixedSize()
            .allowsHitTesting(false)
            .position(x: x, y: -14)
            .transition(.opacity)
    }

    // MARK: Helpers

    private struct Slot: Identifiable {
        let position: Int
        let sample: LatencySample?
        var id: Int { position }
    }

    private func paddedSlots(count: Int) -> [Slot] {
        let recent = Array(samples.suffix(count))
        let empty = count - recent.count
        var slots: [Slot] = []
        slots.reserveCapacity(count)
        for i in 0..<empty {
            slots.append(Slot(position: i, sample: nil))
        }
        for (i, sample) in recent.enumerated() {
            slots.append(Slot(position: empty + i, sample: sample))
        }
        return slots
    }

    private func color(for bucket: LatencyBucket) -> Color {
        switch bucket {
        case .empty:    Color.gray.opacity(0.28)
        // Severity gradient — standard warm-hue progression.
        // Timeout / network error is folded into `.poor` (red).
        case .good:     .green
        case .moderate: .yellow
        case .slow:     .orange
        case .poor:     .red
        }
    }

    private func tooltipText(for slot: Slot) -> String {
        guard let sample = slot.sample else {
            return String(localized: "no data")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: sample.at)
        if let ms = sample.latencyMs {
            return String(format: "%@  %.0f ms", time, ms)
        }
        return "\(time)  " + String(localized: "timeout")
    }

    // MARK: Stats

    private var successfulSamples: [LatencySample] {
        samples.filter { $0.latencyMs != nil }
    }

    private var current: String {
        guard let last = samples.last else { return "—" }
        guard let ms = last.latencyMs else { return "✕" }
        return String(format: "%.0f", ms)
    }

    private var average: String {
        let values = successfulSamples.compactMap(\.latencyMs)
        guard !values.isEmpty else { return "—" }
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "%.0f", avg)
    }

    private var maxValue: String {
        let values = successfulSamples.compactMap(\.latencyMs)
        guard let m = values.max() else { return "—" }
        return String(format: "%.0f", m)
    }

    private func observe() async {
        for await next in environment.latencyService.stream() {
            samples = next
        }
    }
}
