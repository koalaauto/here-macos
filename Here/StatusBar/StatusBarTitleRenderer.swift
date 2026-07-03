import AppKit

enum StatusBarTitleRenderer {
    /// Border style for the pill. Both cases use the standard label
    /// colour so the widget never introduces a foreign hue to the menu
    /// bar; the only cue is line pattern.
    ///
    /// - `.neutral`: solid stroke — normal state.
    /// - `.alert`:   dashed stroke — something's wrong (currently:
    ///               latency probe timed out or exceeded the "poor"
    ///               threshold, so effectively "network not working").
    ///               The broken-line pattern carries the "unstable /
    ///               intermittent" semantic without the shout of a red
    ///               border or the distraction of a pulse animation.
    enum BorderTint: Sendable {
        case neutral
        case alert

        @MainActor
        var color: NSColor { NSColor.labelColor }

        /// Whether the stroke should be dashed rather than solid.
        var isDashed: Bool {
            switch self {
            case .neutral: false
            case .alert:   true
            }
        }
    }

    struct Input: Sendable, Equatable {
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

        return compose(flag: flag, text: text, borderTint: input.borderTint)
    }

    private static func renderCountry(_ input: Input) -> String {
        guard let alpha2 = input.countryAlpha2, !alpha2.isEmpty else { return "??" }
        switch input.countryStyle {
        case .text: return alpha2.uppercased()
        case .flag: return CountryFlag.emoji(alpha2: alpha2) ?? alpha2.uppercased()
        }
    }

    @MainActor
    private static func compose(flag: NSImage?, text: String, borderTint: BorderTint) -> NSImage? {
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
        // Floor the content height to the font's natural line box,
        // even when there's no text. Without this floor, a flag-only
        // pill (`countryOnly` + `flag` style) collapses to the flag's
        // own 10 pt height — and with `vPadding = 1` the flag ends up
        // visually flush with the pill border (no top/bottom margin).
        // Using the font line-height as the baseline keeps all four
        // mode permutations the same overall pill size, so the flag
        // gets the same centred breathing room whether text is
        // beside it or not.
        let baselineHeight = ceil(font.boundingRectForFont.height)
        let contentHeight = max(flagSize.height, textSize.height, baselineHeight)

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
            if borderTint.isDashed {
                // 3 pt dashes with 2 pt gaps — visible at 1 pt stroke
                // without turning the pill into a dotted line.
                path.setLineDash([3, 2], count: 2, phase: 0)
            }
            borderTint.color.setStroke()
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

}
