import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum FlagRenderer {
    /// Render a country flag to an NSImage.
    ///
    /// Prefers a bundled Twemoji PNG (real square flag) and falls back to the
    /// system's Apple Color Emoji if the asset is missing. When the ISO code
    /// is empty/unknown (we're in `.idle / .loading / .error` and don't have
    /// a verified egress yet), returns a small neutral placeholder rectangle
    /// so the menu-bar pill can keep its "flag + code" shape instead of
    /// falling back to a wildly-different SF symbol. Mono variants are
    /// produced by desaturating the source image.
    static func image(alpha2: String, pointSize: CGFloat = 15, mono: Bool) -> NSImage? {
        if !alpha2.isEmpty,
           let source = bundledFlag(alpha2: alpha2) ?? renderEmoji(alpha2: alpha2, pointSize: pointSize) {
            let resized = resize(source, to: pointSize)
            return mono ? desaturated(resized) : resized
        }
        return placeholderFlag(pointSize: pointSize)
    }

    /// Draw a small rounded rectangle in the label color (semi-transparent)
    /// as a stand-in when we don't have a real flag to show. 3:2 aspect
    /// matches the rest of the bundled flag assets so surrounding layout
    /// doesn't jump.
    private static func placeholderFlag(pointSize: CGFloat) -> NSImage? {
        let height = pointSize
        let width = ceil(height * 1.5)
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        image.unlockFocus()
        return image
    }

    private static func bundledFlag(alpha2: String) -> NSImage? {
        let name = "flag_\(alpha2.uppercased())"
        return NSImage(named: name)
    }

    private static func renderEmoji(alpha2: String, pointSize: CGFloat) -> NSImage? {
        guard let emoji = CountryFlag.emoji(alpha2: alpha2) else { return nil }
        let font = NSFont.systemFont(ofSize: pointSize)
        let attrString = NSAttributedString(string: emoji, attributes: [.font: font])
        let measured = attrString.size()
        let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        attrString.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    private static func resize(_ source: NSImage, to pointSize: CGFloat) -> NSImage {
        let aspect = source.size.width / max(source.size.height, 1)
        let targetHeight = pointSize
        let targetWidth = targetHeight * aspect
        let targetSize = NSSize(width: ceil(targetWidth), height: ceil(targetHeight))
        let result = NSImage(size: targetSize)
        result.lockFocusFlipped(false)
        source.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        result.unlockFocus()
        return result
    }

    private static func desaturated(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.saturation = 0
        filter.brightness = 0
        filter.contrast = 1.05
        guard let output = filter.outputImage else { return image }
        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }
}
