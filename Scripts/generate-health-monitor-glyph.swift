// generate-health-monitor-glyph.swift
// Renders the Health Monitor rail glyph: a blue squircle in the section-icon
// style with a white ECG pulse, desaturated to the same light-matte relief as
// the art-derived rail glyphs. Health Monitor ships no 3D hero render, so its
// glyph is authored procedurally here rather than processed from hero art.
// Run from the repo root:
//
//   swift Scripts/generate-health-monitor-glyph.swift
//
import AppKit
import CoreImage

let assets = "VaderCleaner/Assets.xcassets"
let ctx = CIContext()
func col(_ r: Double,_ g: Double,_ b: Double,_ a: Double = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

// The blue squircle base: gradient fill, soft top sheen, drop shadow.
func base(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size)); img.lockFocus()
    NSGraphicsContext.current!.imageInterpolation = .high
    let inset = size * 0.14
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: size * 0.24, yRadius: size * 0.24)
    let sh = NSShadow()
    sh.shadowColor = col(0, 0, 0, 0.45); sh.shadowBlurRadius = size * 0.05
    sh.shadowOffset = NSSize(width: 0, height: -size * 0.025); sh.set()
    NSGradient(colors: [col(0.30, 0.47, 0.80), col(0.13, 0.24, 0.50), col(0.08, 0.15, 0.36)],
               atLocations: [0, 0.6, 1], colorSpace: .sRGB)?.draw(in: squircle, angle: -90)
    NSShadow().set()
    squircle.setClip()
    NSGradient(colors: [col(1, 1, 1, 0.30), col(1, 1, 1, 0)], atLocations: [0, 1], colorSpace: .sRGB)?
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    img.unlockFocus(); return img
}

// A white-tinted SF Symbol on its own transparent layer.
func whiteSymbol(_ name: String, _ pt: CGFloat) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .bold)
    guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
    let o = NSImage(size: s.size); o.lockFocus()
    s.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    col(1, 1, 1, 1).set(); NSRect(origin: .zero, size: s.size).fill(using: .sourceAtop)
    o.unlockFocus(); o.isTemplate = false; return o
}

func healthIcon(_ size: CGFloat) -> NSImage {
    let img = base(size); img.lockFocus()
    NSGraphicsContext.current!.imageInterpolation = .high
    if let s = whiteSymbol("waveform.path.ecg", size * 0.40) {
        let scale = (size * 0.42) / max(s.size.width, s.size.height)
        let dw = s.size.width * scale, dh = s.size.height * scale
        let r = NSRect(x: (size - dw) / 2, y: (size - dh) / 2, width: dw, height: dh)
        let sh = NSShadow()
        sh.shadowColor = col(0, 0, 0, 0.35); sh.shadowBlurRadius = size * 0.02
        sh.shadowOffset = NSSize(width: 0, height: -size * 0.012); sh.set()
        s.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    }
    img.unlockFocus(); return img
}

// Same desaturate + tone-map as Scripts/generate-rail-glyphs.swift, so this
// glyph sits in the same light-matte range as the art-derived ones.
let color = healthIcon(400)
let src = CIImage(data: color.tiffRepresentation!)!
let gray = src.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
let mono = gray.applyingFilter("CIToneCurve", parameters: [
    "inputPoint0": CIVector(x: 0.0,  y: 0.50),
    "inputPoint1": CIVector(x: 0.25, y: 0.64),
    "inputPoint2": CIVector(x: 0.5,  y: 0.77),
    "inputPoint3": CIVector(x: 0.75, y: 0.89),
    "inputPoint4": CIVector(x: 1.0,  y: 0.99)])

let cg = ctx.createCGImage(mono, from: mono.extent)!
let name = "healthMonitorMono"
let dir = "\(assets)/\(name).imageset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
let contents = """
{
  "images" : [
    {
      "filename" : "\(name).png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try! contents.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(dir)")
