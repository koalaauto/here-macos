#!/usr/bin/env swift
// Render the IP Guide app icon at every macOS size and drop the PNGs into
// Assets.xcassets/AppIcon.appiconset/. Also writes a matching Contents.json.
//
// Run from the project root:
//   swift scripts/generate_icon.swift

import AppKit

let outputDir = "IPGuide/Resources/Assets.xcassets/AppIcon.appiconset"

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocusFlipped(false)
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS Big Sur+ icons use a superellipse corner; a 22% plain corner radius
    // is close enough for a utility app and looks consistent with system icons.
    let cornerRadius = size * 0.22
    let clipPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    clipPath.addClip()

    // Background gradient — teal → deep blue, 135° like macOS system icons.
    let top = NSColor(red: 0.22, green: 0.67, blue: 0.82, alpha: 1.0)
    let bottom = NSColor(red: 0.09, green: 0.32, blue: 0.66, alpha: 1.0)
    if let gradient = NSGradient(starting: top, ending: bottom) {
        gradient.draw(in: rect, angle: -60)
    }

    // Globe glyph in the foreground. Palette makes it feel more dimensional
    // than a flat white fill.
    let symbolSize = size * 0.62
    let baseConfig = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
    let paletteConfig = NSImage.SymbolConfiguration(
        paletteColors: [.white, NSColor.white.withAlphaComponent(0.55)]
    )
    let config = baseConfig.applying(paletteConfig)

    if let base = NSImage(systemSymbolName: "globe.americas.fill", accessibilityDescription: nil),
       let globe = base.withSymbolConfiguration(config) {
        let g = globe.size
        let x = (size - g.width) / 2
        let y = (size - g.height) / 2
        globe.draw(in: NSRect(x: x, y: y, width: g.width, height: g.height))
    }

    // Subtle inner highlight along the top edge for a slight glass look.
    let highlight = NSColor.white.withAlphaComponent(0.12)
    highlight.setFill()
    let highlightRect = NSRect(x: 0, y: size * 0.55, width: size, height: size * 0.45)
    NSBezierPath(rect: highlightRect).fill()

    return image
}

func writePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "iconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "encode failed"])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

struct Entry {
    let renderPixels: CGFloat
    let filename: String
    let idiom: String
    let size: String
    let scale: String
}

let entries: [Entry] = [
    Entry(renderPixels: 16,   filename: "icon_16x16.png",      idiom: "mac", size: "16x16",     scale: "1x"),
    Entry(renderPixels: 32,   filename: "icon_16x16@2x.png",   idiom: "mac", size: "16x16",     scale: "2x"),
    Entry(renderPixels: 32,   filename: "icon_32x32.png",      idiom: "mac", size: "32x32",     scale: "1x"),
    Entry(renderPixels: 64,   filename: "icon_32x32@2x.png",   idiom: "mac", size: "32x32",     scale: "2x"),
    Entry(renderPixels: 128,  filename: "icon_128x128.png",    idiom: "mac", size: "128x128",   scale: "1x"),
    Entry(renderPixels: 256,  filename: "icon_128x128@2x.png", idiom: "mac", size: "128x128",   scale: "2x"),
    Entry(renderPixels: 256,  filename: "icon_256x256.png",    idiom: "mac", size: "256x256",   scale: "1x"),
    Entry(renderPixels: 512,  filename: "icon_256x256@2x.png", idiom: "mac", size: "256x256",   scale: "2x"),
    Entry(renderPixels: 512,  filename: "icon_512x512.png",    idiom: "mac", size: "512x512",   scale: "1x"),
    Entry(renderPixels: 1024, filename: "icon_512x512@2x.png", idiom: "mac", size: "512x512",   scale: "2x"),
]

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for entry in entries {
    let image = renderIcon(size: entry.renderPixels)
    let path = "\(outputDir)/\(entry.filename)"
    do {
        try writePNG(image, to: path)
        print("wrote \(path) (\(Int(entry.renderPixels))px)")
    } catch {
        print("failed \(path): \(error)")
    }
}

// Generate Contents.json so the asset catalog picks them up.
struct ImageEntry: Encodable { let filename: String; let idiom: String; let scale: String; let size: String }
struct Catalog: Encodable {
    let images: [ImageEntry]
    struct Info: Encodable { let author: String; let version: Int }
    let info: Info
}

let catalog = Catalog(
    images: entries.map {
        ImageEntry(filename: $0.filename, idiom: $0.idiom, scale: $0.scale, size: $0.size)
    },
    info: .init(author: "xcode", version: 1)
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let json = try encoder.encode(catalog)
try json.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("wrote \(outputDir)/Contents.json")
