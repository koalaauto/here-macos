import AppKit

enum StatusBarTitleRenderer {
    /// Border-color bucket for the pill. Keyed to the most-recent latency
    /// sample's classification so a glance at the menu bar tells the user
    /// whether the connection is healthy without opening the popover.
    /// `.neutral` is the default when latency isn't enabled, the probe
    /// hasn't collected a sample yet, or the egress is in an
    /// unknown state.
    enum BorderTint: Sendable {
        case neutral
        case good
        case moderate
        case slow
        case poor

        @MainActor
        var color: NSColor {
            switch self {
            case .neutral:  NSColor.labelColor.withAlphaComponent(0.65)
            case .good:     NSColor.systemGreen.withAlphaComponent(0.85)
            case .moderate: NSColor.systemYellow.withAlphaComponent(0.95)
            case .slow:     NSColor.systemOrange.withAlphaComponent(0.9)
            case .poor:     NSColor.systemRed.withAlphaComponent(0.9)
            }
        }
    }

    struct Input: Sendable {
        let countryAlpha2: String?
        let regionCode: String?
        let showMode: ShowMode
        let countryStyle: CountryStyle
        let borderTint: BorderTint
        let flagMono: Bool
    }

    static func plain(_ input: Input) -> String {
        let country = renderCountry(input)
        let region = input.regionCode?.uppercased() ?? "??"
        switch input.showMode {
        case .countryOnly: return country
        case .regionOnly: return region
        case .both: return "\(country) \(region)"
        }
    }

    @MainActor
    static func renderImage(_ input: Input) -> NSImage? {
        let alpha2 = input.countryAlpha2 ?? ""
        let region = input.regionCode?.uppercased() ?? "??"

        // The pill already draws attention via its border, so shrink the
        // flag to stay visually calm inside it.
        let flagHeight: CGFloat = 10

        let showFlag = input.countryStyle == .flag && input.showMode != .regionOnly
        let flag: NSImage? = showFlag
            ? FlagRenderer.image(alpha2: alpha2, pointSize: flagHeight, mono: input.flagMono)
            : nil

        let text: String
        switch input.showMode {
        case .countryOnly:
            text = showFlag ? "" : (alpha2.isEmpty ? "??" : alpha2)
        case .regionOnly:
            text = region
        case .both:
            text = showFlag ? region : "\(alpha2.isEmpty ? "??" : alpha2) \(region)"
        }

        return compose(flag: flag, text: text, borderColor: input.borderTint.color)
    }

    private static func renderCountry(_ input: Input) -> String {
        guard let alpha2 = input.countryAlpha2, !alpha2.isEmpty else { return "??" }
        switch input.countryStyle {
        case .text: return alpha2.uppercased()
        case .flag: return CountryFlag.emoji(alpha2: alpha2) ?? alpha2.uppercased()
        }
    }

    @MainActor
    private static func compose(flag: NSImage?, text: String, borderColor: NSColor) -> NSImage? {
        // Inside the pill we drop 2pt off the menu bar default to stay
        // visually calm — the border frame already draws the eye.
        let defaultSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let font = NSFont.menuBarFont(ofSize: max(defaultSize - 2, 9))
        let textAttr: NSAttributedString? = text.isEmpty
            ? nil
            : NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ]
            )
        let textSize = textAttr?.size() ?? .zero
        let flagSize = flag?.size ?? .zero

        let spacing: CGFloat = (flag != nil && textAttr != nil) ? 3 : 0
        let vPadding: CGFloat = 1
        let hPadding: CGFloat = 4

        let contentWidth = flagSize.width + spacing + textSize.width
        let contentHeight = max(flagSize.height, textSize.height)

        guard contentWidth > 0, contentHeight > 0 else { return nil }

        let totalWidth = ceil(contentWidth + hPadding * 2)
        let totalHeight = ceil(contentHeight + vPadding * 2)
        let imageSize = NSSize(width: totalWidth, height: totalHeight)

        let image = NSImage(size: imageSize, flipped: false) { _ in
            let rect = NSRect(
                x: 0.5, y: 0.5,
                width: imageSize.width - 1,
                height: imageSize.height - 1
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.lineWidth = 1
            borderColor.setStroke()
            path.stroke()

            var x = hPadding
            if let flag {
                let y = (imageSize.height - flagSize.height) / 2
                flag.draw(in: NSRect(x: x, y: y, width: flagSize.width, height: flagSize.height))
                x += flagSize.width + spacing
            }
            if let textAttr {
                let y = (imageSize.height - textSize.height) / 2
                textAttr.draw(at: NSPoint(x: x, y: y))
            }
            return true
        }
        return image
    }

    static var placeholder: String { "— —" }
}
