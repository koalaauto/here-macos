import AppKit

enum StatusBarTitleRenderer {
    struct Input: Sendable {
        let countryAlpha2: String?
        let regionCode: String?
        let showMode: ShowMode
        let countryStyle: CountryStyle
        let bordered: Bool
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

        // Inside the pill (bordered) the box already draws attention; shrink the flag
        // to match. Without a pill, the flag carries the whole visual so give it room.
        let flagHeight: CGFloat = input.bordered ? 10 : 14

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

        return compose(flag: flag, text: text, bordered: input.bordered)
    }

    private static func renderCountry(_ input: Input) -> String {
        guard let alpha2 = input.countryAlpha2, !alpha2.isEmpty else { return "??" }
        switch input.countryStyle {
        case .text: return alpha2.uppercased()
        case .flag: return CountryFlag.emoji(alpha2: alpha2) ?? alpha2.uppercased()
        }
    }

    @MainActor
    private static func compose(flag: NSImage?, text: String, bordered: Bool) -> NSImage? {
        // Bordered pill drops 2pt off the menu bar default to stay visually calm;
        // the un-bordered variant uses the full default so the label holds its
        // own next to other menu bar items.
        let defaultSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let font = bordered
            ? NSFont.menuBarFont(ofSize: max(defaultSize - 2, 9))
            : NSFont.menuBarFont(ofSize: defaultSize)
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
        let vPadding: CGFloat = bordered ? 1 : 0
        let hPadding: CGFloat = bordered ? 4 : 0

        let contentWidth = flagSize.width + spacing + textSize.width
        let contentHeight = max(flagSize.height, textSize.height)

        guard contentWidth > 0, contentHeight > 0 else { return nil }

        let totalWidth = ceil(contentWidth + hPadding * 2)
        let totalHeight = ceil(contentHeight + vPadding * 2)
        let imageSize = NSSize(width: totalWidth, height: totalHeight)

        let image = NSImage(size: imageSize, flipped: false) { _ in
            if bordered {
                let borderColor = NSColor.labelColor.withAlphaComponent(0.65)
                let rect = NSRect(
                    x: 0.5, y: 0.5,
                    width: imageSize.width - 1,
                    height: imageSize.height - 1
                )
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                path.lineWidth = 1
                borderColor.setStroke()
                path.stroke()
            }

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
