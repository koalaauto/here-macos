import AppKit
import MapKit
import SwiftUI

struct LocationCard: View {
    let model: IPDataModel

    @State private var mapHovering = false
    @State private var networkExpanded = false

    private var cameraPosition: MapCameraPosition {
        .region(MKCoordinateRegion(
            center: model.coordinate,
            latitudinalMeters: 50_000,
            longitudinalMeters: 50_000
        ))
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                mapView
                timezoneRow
                Divider().padding(.vertical, 2)
                networkDisclosure
            }
        }
    }

    // MARK: Map

    private var mapView: some View {
        Map(initialPosition: cameraPosition, interactionModes: []) {
            Marker(model.location.city, coordinate: model.coordinate)
                .tint(.red)
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if mapHovering {
                Image(systemName: "arrow.up.forward.square.fill")
                    .font(.callout)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .padding(6)
                    .help(String(localized: "Open in Maps"))
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                mapHovering = hovering
            }
        }
        .onTapGesture { openInMaps() }
    }

    // MARK: Timezone

    private var timezoneRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(localized: "Timezone"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(timezoneAbbreviation)
                .lineLimit(1)
                .help(model.location.timezone)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(localTimeString(at: context.date))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Custom network disclosure (whole header row clickable)

    private var networkDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                networkExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(networkExpanded ? 90 : 0))
                        // Instant rotation — no `.animation` modifier, because
                        // that would also catch the 1-2pt y-shift the HStack
                        // produces when the ASN summary appears/disappears,
                        // making the chevron look like it "jumps" vertically.
                    Text(String(localized: "Network"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    if !networkExpanded {
                        Text(model.asnLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            if networkExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    CopyableRow(label: String(localized: "CIDR"),
                                value: model.network.cidr,
                                monospaced: true,
                                copyable: false)
                    CopyableRow(label: String(localized: "ASN"),
                                value: model.asnLabel,
                                copyable: false)
                    CopyableRow(label: String(localized: "Org"),
                                value: model.network.autonomousSystem.organization,
                                copyable: false)
                    CopyableRow(label: String(localized: "RIR"),
                                value: model.network.autonomousSystem.rir,
                                copyable: false)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: Helpers

    private var timezoneAbbreviation: String {
        guard let tz = TimeZone(identifier: model.location.timezone) else {
            return model.location.timezone
        }
        if let abbr = tz.abbreviation() {
            let cityPart = model.location.timezone
                .split(separator: "/")
                .last
                .map { String($0).replacingOccurrences(of: "_", with: " ") }
                ?? model.location.timezone
            return "\(abbr) · \(cityPart)"
        }
        return model.location.timezone
    }

    private func localTimeString(at date: Date) -> String {
        let tz = TimeZone(identifier: model.location.timezone) ?? TimeZone.current
        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: model.coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = model.location.city
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: model.coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(
                latitudeDelta: 0.5, longitudeDelta: 0.5
            ))
        ])
    }
}
