// SpaceLensPalette.swift
// Gives every Space Lens tile its own vivid color — hue is fanned evenly across sibling tiles so each is visibly distinct, shaded per-node for variety, drawn as a gradient, and paired with an adaptive label color that stays legible on any tile.

import SwiftUI
import AppKit

/// Per-tile color generation shared by `TreemapView` and `SunburstView`.
///
/// Color here is purely visual identity (DaisyDisk-style) — it does not encode
/// file type. The caller supplies each tile's **hue** from its position among
/// its siblings (the treemap fans hues evenly across a folder's children; the
/// sunburst keys hue to a segment's angle), which *guarantees* neighbouring
/// tiles get distinct hues rather than hoping a hash spreads them. The palette
/// then derives saturation and brightness from a stable hash of the node's
/// path, so tiles sharing a hue still differ in shade and a given node keeps its
/// shade across resizes and launches. Each tile is painted as a top-light →
/// bottom-dark gradient for depth.
///
/// Legibility is handled where it belongs: `labelColor(hue:for:)` measures the
/// tile's brightness and returns black or white, whichever clears a WCAG AA
/// contrast ratio. That frees the fills to be as vibrant as they like — the
/// text adapts rather than the palette dimming to accommodate it.
enum SpaceLensPalette {

    // MARK: - Hue assignment

    /// The hue for a tile at `index` among `count` siblings, fanned evenly
    /// around the color wheel so every sibling lands on a clearly different
    /// hue. Used by the treemap, which lays out one folder's children at a time.
    static func hue(forChildAt index: Int, of count: Int) -> Double {
        guard count > 0 else { return 0 }
        return Double(index) / Double(count)
    }

    // MARK: - Public API

    /// The gradient fill for a node's tile/arc at the given hue. Built around
    /// the node's vivid color: a lighter shade at the top-leading edge easing
    /// into a darker shade at the bottom-trailing, which reads as a lit surface
    /// rather than a flat fill. `opacity` carries the hover / depth fade the
    /// caller already computes.
    static func gradient(hue: Double, for node: DiskNode, opacity: Double = 1) -> LinearGradient {
        let top = topColor(hue: hue, for: node)
        let bottom = bottomColor(hue: hue, for: node)
        return LinearGradient(
            colors: [top.opacity(opacity), bottom.opacity(opacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Black or white, whichever has more contrast against the lightest region
    /// of the tile (its gradient top, where the treemap draws its label). The
    /// better of the two always clears WCAG AA 4.5:1 against an opaque tile, so
    /// labels stay readable no matter how vivid the fill.
    static func labelColor(hue: Double, for node: DiskNode) -> Color {
        let topLuminance = topColor(hue: hue, for: node).relativeLuminance
        // Compare against each candidate's *actual* luminance — the dark label
        // is near-black but not zero, and using its true value is what keeps the
        // chosen option genuinely the higher-contrast one at the boundary.
        let whiteContrast = contrastRatio(topLuminance, Color.white.relativeLuminance)
        let darkContrast = contrastRatio(topLuminance, Self.darkLabel.relativeLuminance)
        return whiteContrast >= darkContrast ? .white : Self.darkLabel
    }

    /// The lightest region of a tile — its gradient top, where the treemap
    /// draws its label. Single source of truth shared by `gradient` and
    /// `labelColor` so the label decision is made against the exact color the
    /// text lands on; exposed for tests to verify that contrast.
    static func topColor(hue: Double, for node: DiskNode) -> Color {
        renderColor(hue: hue, for: node).adjusted(brightness: 1.10, saturation: 0.92)
    }

    /// The node's mid base color before the gradient lightening / darkening —
    /// exposed for tests and any future legend swatch wanting one representative
    /// color per tile.
    static func baseColor(hue: Double, for node: DiskNode) -> Color {
        renderColor(hue: hue, for: node)
    }

    /// The near-black label color, exposed so tests can confirm it is exactly
    /// what `labelColor` returns for a light tile.
    static var darkLabelColor: Color { darkLabel }

    // MARK: - Color generation

    /// Near-black label color — a hair of warmth rather than pure black so dark
    /// text on a bright tile doesn't read as a harsh hole, but kept dark enough
    /// (luminance ≈ 0.001) that it clears WCAG AA against every tile a bright
    /// fill can produce. A visibly lighter "dark" label would fail contrast on
    /// mid-brightness tiles, which is exactly the bug this value avoids.
    private static let darkLabel = Color(red: 0.02, green: 0.01, blue: 0.02)

    /// The node's vivid color at the caller's hue. Saturation and brightness
    /// come from two decorrelated hashes of the path, kept in a vivid band so
    /// nothing reads washed-out or muddy, so two tiles that happen to share a
    /// hue still differ in shade. Directories are dimmed a touch under files,
    /// the one cue carried over from the old scheme.
    private static func renderColor(hue: Double, for node: DiskNode) -> Color {
        let path = node.url.path
        let saturationSeed = normalizedHash(path + "\u{1}sat")
        let brightnessSeed = normalizedHash(path + "\u{1}bri")

        let saturation = 0.62 + saturationSeed * 0.30
        let directoryDim = node.isDirectory ? 0.92 : 1.0
        let brightness = min(1.0, (0.74 + brightnessSeed * 0.24) * directoryDim)
        return Color(hue: wrapHue(hue), saturation: saturation, brightness: brightness)
    }

    private static func bottomColor(hue: Double, for node: DiskNode) -> Color {
        renderColor(hue: hue, for: node).adjusted(brightness: 0.74, saturation: 1.05)
    }

    /// A stable [0, 1) seed from a string via FNV-1a. Deterministic across
    /// launches (unlike `Hashable.hashValue`, which is per-process salted), so a
    /// given node keeps the same shade every session.
    private static func normalizedHash(_ string: String) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Double(hash % 1_000_000) / 1_000_000.0
    }

    /// Fold a hue into [0, 1) so callers can pass an angle fraction that lands
    /// slightly above 1.0 or below 0.
    private static func wrapHue(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 1.0)
        return wrapped < 0 ? wrapped + 1.0 : wrapped
    }

    // MARK: - Contrast

    /// WCAG contrast ratio between two relative luminances (1…21).
    private static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

// MARK: - Color math

private extension Color {
    /// HSB decomposition via `NSColor` in sRGB, so the palette can re-light a
    /// generated color for the gradient stops.
    var hsbComponents: (hue: Double, saturation: Double, brightness: Double) {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return (
            Double(nsColor.hueComponent),
            Double(nsColor.saturationComponent),
            Double(nsColor.brightnessComponent)
        )
    }

    /// This color with its brightness and saturation scaled (both clamped to
    /// the valid 0…1 range). Used to build the lighter top and darker bottom of
    /// each tile's gradient.
    func adjusted(brightness brightnessFactor: Double, saturation saturationFactor: Double) -> Color {
        let hsb = hsbComponents
        return Color(
            hue: hsb.hue,
            saturation: min(1.0, max(0.0, hsb.saturation * saturationFactor)),
            brightness: min(1.0, max(0.0, hsb.brightness * brightnessFactor))
        )
    }

    /// WCAG relative luminance (0…1) of the color in sRGB. Drives the
    /// black-or-white label decision.
    var relativeLuminance: Double {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        func linear(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(nsColor.redComponent)
            + 0.7152 * linear(nsColor.greenComponent)
            + 0.0722 * linear(nsColor.blueComponent)
    }
}
