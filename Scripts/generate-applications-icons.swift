// generate-applications-icons.swift
// Generates the two Applications-section card icons (App Leftovers, installer DMG)
// as glossy gradient tiles with a white SF Symbol glyph, baked into universal
// PNG imagesets. Original artwork in the section's colourful style. Run from the
// repo root:
//
//   swift Scripts/generate-applications-icons.swift
//
import AppKit

let assets = "VaderCleaner/Assets.xcassets"
let side: CGFloat = 256

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

/// White-tints a template SF Symbol so it draws as a solid white glyph.
func whiteGlyph(_ name: String, pointSize: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("missing SF Symbol \(name)")
    }
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

/// Draws a glossy rounded-rect gradient tile with a centred white glyph.
func makeIcon(top: NSColor, bottom: NSColor, glyph: String, glyphScale: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let inset: CGFloat = 18
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius: CGFloat = (side - inset * 2) * 0.28
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Diagonal body gradient.
    NSGradient(colors: [top, bottom])!.draw(in: tile, angle: -65)

    // Soft top gloss: a translucent white highlight over the upper third.
    tile.addClip()
    let glossRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.28),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    gloss.draw(in: glossRect, angle: -90)

    // Centred white glyph.
    let glyphImage = whiteGlyph(glyph, pointSize: 150)
    let target = rect.width * glyphScale
    let aspect = glyphImage.size.height / max(glyphImage.size.width, 1)
    let glyphSize = NSSize(width: target, height: target * aspect)
    let glyphRect = NSRect(
        x: rect.midX - glyphSize.width / 2,
        y: rect.midY - glyphSize.height / 2,
        width: glyphSize.width,
        height: glyphSize.height
    )
    glyphImage.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)

    image.unlockFocus()
    return image
}

let contentsTemplate = """
{
  "images" : [
    {
      "filename" : "%@.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

func bake(_ name: String, _ image: NSImage) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode \(name)")
    }
    let dir = "\(assets)/\(name).imageset"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try! png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    try! String(format: contentsTemplate, name)
        .write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
    print("wrote \(dir)")
}

// App Leftovers — blue→purple tile with a puzzle-piece glyph.
bake("appLeftovers", makeIcon(
    top: color(96, 150, 255),
    bottom: color(138, 92, 246),
    glyph: "puzzlepiece.extension.fill",
    glyphScale: 0.56
))

// Installer DMG — blue tile with an external-drive glyph.
bake("installerDmg", makeIcon(
    top: color(86, 170, 255),
    bottom: color(30, 111, 224),
    glyph: "externaldrive.fill",
    glyphScale: 0.58
))
