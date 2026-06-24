// generate-rail-glyphs.swift
// Regenerates the monochrome navigation-rail glyph imagesets from the colour
// section hero imagesets, so the rail icons stay in sync with the hero art.
//
// Each rail glyph is the hero render desaturated and tone-mapped to a light
// matte gray (alpha preserved). The rail renders it neutral when inactive and
// multiplies it by the section accent when active. Run from the repo root:
//
//   swift Scripts/generate-rail-glyphs.swift
//
import AppKit
import CoreImage

// Section enum case name -> its colour hero imageset name (same string here).
let sections = ["smartScan", "systemJunk", "largeOldFiles", "spaceLens",
                "malwareRemoval", "performance", "privacy", "applications"]

let assets = "VaderCleaner/Assets.xcassets"
let ctx = CIContext()

func mono(_ url: URL) -> CIImage? {
    guard let img = CIImage(contentsOf: url) else { return nil }
    // Strip colour, then map blacks to mid-gray and whites to near-white so
    // every glyph lands in the same light matte range regardless of its hue.
    let gray = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
    return gray.applyingFilter("CIToneCurve", parameters: [
        "inputPoint0": CIVector(x: 0.0,  y: 0.50),
        "inputPoint1": CIVector(x: 0.25, y: 0.64),
        "inputPoint2": CIVector(x: 0.5,  y: 0.77),
        "inputPoint3": CIVector(x: 0.75, y: 0.89),
        "inputPoint4": CIVector(x: 1.0,  y: 0.99)])
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

for section in sections {
    let src = URL(fileURLWithPath: "\(assets)/\(section).imageset/\(section).heif")
    guard let m = mono(src), let cg = ctx.createCGImage(m, from: m.extent) else {
        print("FAILED \(section)"); continue
    }
    let name = "\(section)Mono"
    let dir = "\(assets)/\(name).imageset"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    try! String(format: contentsTemplate, name).write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
    print("wrote \(dir)")
}
