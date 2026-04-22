import AppKit
import SwiftUI

extension VerticalAlignment {
    /// Custom alignment used by the history chain so inter-chip arrows line
    /// up with the vertical center of the country flag, not with the chip's
    /// overall center (which sits lower because of the duration label
    /// underneath). Set on the flag via `.alignmentGuide(.flagMidline)` and
    /// consumed by the parent HStack via `HStack(alignment: .flagMidline)`.
    private enum FlagMidline: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat {
            d[VerticalAlignment.center]
        }
    }

    static let flagMidline = VerticalAlignment(FlagMidline.self)
}

/// Horizontal "flag chain" of recent egress-IP changes:
///
///     🇯🇵 →  🇺🇸 →  🇸🇬 (now, green dot)
///     2h     30m    2m
///
/// Each chip's label is "how long ago this event started" (not the duration
/// stayed — that reading requires the user to sum prior entries). Clicking
/// a chip toggles a detail row with IP + ASN + city for that period.
///
/// Events older than `maxChips` are silently dropped from the visible chain;
/// the total change count in the header still reflects them. The chain is
/// right-anchored so the current egress is always the rightmost chip and
/// arrows align with the flag row via a custom `.flagMidline` alignment.
struct HistoryCard: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var events: [IPChangeEvent] = []
    @State private var selectedID: UUID?

    // Fill the chain with as many chips as fit comfortably in the popover
    // width. Older events beyond this cap are silently dropped from the
    // visible chain (no "+N more" indicator) — the newest-on-right anchor
    // keeps the current egress always visible.
    //
    // 6 chips turns out to be too tight: the "Nm" label on the leftmost
    // chip wraps to two lines under HStack compression, making the row
    // look crooked. 5 chips leaves enough horizontal slack for all chips
    // to lay out evenly.
    private let maxChips = 5

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
        // Distribute chips edge-to-edge: first chip pinned to the leading
        // edge, last chip pinned to the trailing edge, remaining space
        // shared evenly around the arrows between them. Flexible `Spacer`s
        // flanking each arrow do the work — HStack gives each Spacer an
        // equal slice of the residual width, so the visual gaps match
        // regardless of how many events exist.
        //
        // Newest still lands on the right (Latency-style time axis); older
        // events beyond `maxChips` get dropped from the visible chain,
        // with the header's `N changes` counter reflecting the true total.
        //
        // Wrapped in a `TimelineView` with a 30 s periodic tick so each
        // chip's "time ago" label stays live — without it, "28m" would
        // stay "28m" until the next IP change fires a re-render.
        let displayed = Array(events.suffix(maxChips))
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .flagMidline, spacing: 0) {
                // With a single chip the HStack would center it by default,
                // which breaks the newest-on-right time-axis convention.
                // Push the lone chip to the trailing edge so the chain
                // always reads "past → present" with present pinned right.
                if displayed.count == 1 {
                    Spacer(minLength: 0)
                }
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, event in
                    if index > 0 {
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                    }
                    chip(for: event, isCurrent: index == displayed.count - 1, now: context.date)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func chip(for event: IPChangeEvent, isCurrent: Bool, now: Date) -> some View {
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
                    // Anchor the custom `flagMidline` alignment to the flag's
                    // own vertical center, so the HStack pulls inter-chip
                    // arrows up to the flag row instead of the chip's overall
                    // midpoint (which is lower because of the label below).
                    .alignmentGuide(.flagMidline) { d in d[VerticalAlignment.center] }
                Text(timeAgoLabel(for: event, now: now))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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

    /// "Time ago" the event happened, relative to `now`.
    ///
    /// This is the natural reading of a timestamp under a flag: "I was at
    /// this country 3h ago". Duration-stayed (how long we sat on this IP
    /// before the next change) reads as a time number but means something
    /// structurally different — to figure out WHEN an event happened the
    /// user has to sum all the prior durations, which defeats the purpose
    /// of a glance-able history. Matches the "Updated N min. ago" label in
    /// the popover footer.
    ///
    /// `now` is piped in from the chain's `TimelineView` so labels keep
    /// advancing even when the history list itself hasn't changed.
    private func timeAgoLabel(for event: IPChangeEvent, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(event.at))
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
