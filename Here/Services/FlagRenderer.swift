import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum FlagRenderer {
    /// Render a country flag to an NSImage.
    ///
    /// Prefers a bundled Twemoji PNG (real square flag) and falls back to the
    /// system's Apple Color Emoji if the asset is missing. Mono variants are
    /// produced by desaturating the source image.
    static func image(alpha2: String, pointSize: CGFloat = 15, mono: Bool) -> NSImage? {
        let source = bundledFlag(alpha2: alpha2) ?? renderEmoji(alpha2: alpha2, pointSize: pointSize)
        guard let source else { return nil }
        let resized = resize(source, to: pointSize)
        return mono ? desaturated(resized) : resized
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
