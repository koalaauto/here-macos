import AppKit
import SwiftUI

/// Horizontal "flag chain" of recent egress-IP changes:
///
///     🇯🇵 →  🇺🇸 →  🇸🇬 (now)
///     30m    12m    2m
///
/// Click a chip to toggle a small detail row showing the IP + ASN for that
/// period. Width-aware: if more than `maxChips` events exist, the older ones
/// collapse into a "+N more" badge at the head.
struct HistoryCard: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var events: [IPChangeEvent] = []
    @State private var selectedID: UUID?

    private let maxChips = 4

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                header
                if events.isEmpty {
                    emptyState
                } else {
                    chain
                    if let id = selectedID,
                       let event = events.first(where: { $0.id == id }) {
                        detail(for: event)
                    }
                }
            }
        }
        .task { await observe() }
    }

    // MARK: Sub-views

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "History"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if events.count > 1 {
                Text(String.localizedStringWithFormat(
                    String(localized: "%d changes"),
                    events.count - 1
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyState: some View {
        Text(String(localized: "Your IP hasn't changed yet — we'll track it here."))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private var chain: some View {
        // Anchor the chain to the RIGHT edge of the card — newest chip sits
        // at the far right (matches the Latency bar, where the most recent
        // sample is the rightmost cell). As you read leftward, you travel
        // back in time; "+N more" is the last visible "…and further" marker
        // before the clipped older tail.
        let displayed = Array(events.suffix(maxChips))
        let hiddenCount = max(0, events.count - displayed.count)
        return HStack(spacing: 6) {
            Spacer(minLength: 0)
            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 2)
            }
            ForEach(Array(displayed.enumerated()), id: \.element.id) { index, event in
                chip(for: event, isCurrent: index == displayed.count - 1)
                if index < displayed.count - 1 {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func chip(for event: IPChangeEvent, isCurrent: Bool) -> some View {
        Button {
            // No `withAnimation` / `.transition` — expanding the detail row
            // grows the card, and any animation on that size change leaks
            // into sibling modules below (they slide down from the top).
            // Snap open like the Network disclosure does.
            selectedID = selectedID == event.id ? nil : event.id
        } label: {
            VStack(spacing: 3) {
                flagImage(for: event.countryCode)
                    .frame(width: 30, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
                    .opacity(isCurrent ? 1 : 0.85)
                Text(durationLabel(for: event))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isCurrent ? .primary : .secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectedID == event.id ? Color.accentColor.opacity(0.18) : .clear)
            )
            .overlay(alignment: .topTrailing) {
                if isCurrent {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(tooltipText(for: event, isCurrent: isCurrent))
    }

    @ViewBuilder
    private func flagImage(for countryCode: String) -> some View {
        if let ns = NSImage(named: "flag_\(countryCode.uppercased())") {
            Image(nsImage: ns)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else if let emoji = CountryFlag.emoji(alpha2: countryCode) {
            Text(emoji).font(.title3)
        } else {
            Text(countryCode)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
    }

    private func detail(for event: IPChangeEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(event.ip)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                Text("·").foregroundStyle(.tertiary)
                Text("\(event.countryName) · \(event.city)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(event.asnLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(absoluteTimestamp(event.at))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Formatters

    /// Human-readable duration for how long we stayed at this event's IP.
    /// For the most recent event it's "from `at` until now"; for older
    /// events it's "from this event's `at` until the NEXT event's `at`".
    private func durationLabel(for event: IPChangeEvent) -> String {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return "" }
        let endDate: Date
        if index == events.count - 1 {
            endDate = Date()
        } else {
            endDate = events[index + 1].at
        }
        let seconds = max(0, endDate.timeIntervalSince(event.at))
        return formatDuration(seconds)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60   { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let hours = total / 3600
        if hours < 48   { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private func absoluteTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · HH:mm"
        return formatter.string(from: date)
    }

    private func tooltipText(for event: IPChangeEvent, isCurrent: Bool) -> String {
        let prefix = isCurrent
            ? String(localized: "Now")
            : absoluteTimestamp(event.at)
        return "\(prefix)  ·  \(event.countryName) · \(event.city)  ·  \(event.ip)"
    }

    // MARK: Observation

    private func observe() async {
        for await next in environment.historyService.stream() {
            events = next
        }
    }
}
