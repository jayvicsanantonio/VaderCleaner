// SpaceLensPaletteTests.swift
// Verifies SpaceLensPalette fans sibling hues evenly so every tile is distinct, shades tiles stably per node, and pairs every tile with a label color that clears WCAG AA contrast.

import XCTest
import SwiftUI
import AppKit
@testable import VaderCleaner

final class SpaceLensPaletteTests: XCTestCase {

    // MARK: - Sibling hue fan

    /// The property the chart is judged on: the tiles in one folder must each
    /// get a clearly distinct hue. The even fan guarantees it — for any sibling
    /// count the hues are all different and spread a full turn apart.
    func test_hueFan_givesEverySiblingADistinctHue() {
        for count in [2, 5, 7, 12, 20] {
            let hues = (0..<count).map { SpaceLensPalette.hue(forChildAt: $0, of: count) }
            XCTAssertEqual(Set(hues).count, count, "\(count) siblings produced duplicate hues")

            let sorted = hues.sorted()
            let minGap = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.min() ?? 0
            XCTAssertEqual(
                minGap,
                1.0 / Double(count),
                accuracy: 1e-9,
                "\(count) siblings aren't evenly fanned around the wheel"
            )
        }
    }

    /// Distinct hues must survive becoming actual tile colors — two siblings a
    /// fan-step apart resolve to visibly different fills, not collapsed by the
    /// shade variation.
    func test_baseColor_isDistinctAcrossSiblings() {
        let count = 12
        let colors = (0..<count).map { index -> Color in
            let node = makeNode(path: "/Users/example/folder_\(index)")
            return SpaceLensPalette.baseColor(for: node, hueIndex: index, of: count)
        }
        XCTAssertEqual(Set(colors).count, count, "Sibling tiles collapsed onto \(Set(colors).count)/\(count) colors")
    }

    // MARK: - Per-node shade

    /// Two tiles that happen to share a hue still differ in shade, so repeated
    /// hues across different folders don't look identical. Same hue, many nodes,
    /// overwhelmingly distinct colors.
    func test_baseColor_variesByNodeAtAFixedHue() {
        let colors = (0..<60).map { index -> Color in
            let node = makeNode(path: "/Users/example/clip_\(index).mp4")
            return SpaceLensPalette.baseColor(hue: 0.4, for: node)
        }
        XCTAssertGreaterThan(
            Set(colors).count,
            54,
            "Tiles at one hue collapsed onto \(Set(colors).count) shades — too little per-node variety"
        )
    }

    /// A node's color must not flicker: same node and hue resolve to the same
    /// color every call, which keeps the chart steady across resizes.
    func test_baseColor_isStableForTheSameNodeAndHue() {
        let node = makeNode(path: "/Users/example/Movies/clip.mp4")
        XCTAssertEqual(
            SpaceLensPalette.baseColor(hue: 0.2, for: node),
            SpaceLensPalette.baseColor(hue: 0.2, for: node)
        )
    }

    // MARK: - Legibility

    /// The load-bearing test. Across the full hue wheel, both file and directory
    /// tiles, and many per-node shades, the label color the palette picks must
    /// clear WCAG AA (4.5:1) against the lightest region of the tile it sits on.
    /// This is what lets the fills be vivid without the text becoming unreadable.
    func test_labelColor_clearsWCAGContrastOnEveryTile() {
        for hueStep in 0..<60 {
            let hue = Double(hueStep) / 60.0
            for isDirectory in [true, false] {
                for nodeIndex in 0..<5 {
                    let node = makeNode(path: "/Users/example/item_\(hueStep)_\(nodeIndex)", isDirectory: isDirectory)
                    let label = SpaceLensPalette.labelColor(hue: hue, for: node)
                    let background = SpaceLensPalette.topColor(hue: hue, for: node)
                    let ratio = contrastRatio(label, background)
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        4.5,
                        "hue \(hue), \(isDirectory ? "dir" : "file") #\(nodeIndex): label contrast \(ratio):1 is below AA"
                    )
                }
            }
        }
    }

    /// The label color is only ever the two we render — pure white or the
    /// near-black `darkLabelColor`. Guards against a future tweak quietly
    /// returning a mid-gray that the contrast test might still pass by luck.
    func test_labelColor_isAlwaysBlackOrWhite() {
        let allowed = Set([Color.white, SpaceLensPalette.darkLabelColor])
        for hueStep in 0..<24 {
            let node = makeNode(path: "/Users/example/label_\(hueStep)")
            let label = SpaceLensPalette.labelColor(hue: Double(hueStep) / 24.0, for: node)
            XCTAssertTrue(allowed.contains(label), "hue step \(hueStep) produced an unexpected label color")
        }
    }

    // MARK: - Helpers

    private func makeNode(path: String, isDirectory: Bool = false) -> DiskNode {
        DiskNode(
            url: URL(fileURLWithPath: path),
            name: URL(fileURLWithPath: path).lastPathComponent,
            size: 1024,
            isDirectory: isDirectory,
            children: []
        )
    }

    /// WCAG contrast ratio between two opaque colors, computed independently of
    /// the palette's own math so the test is a real check, not a tautology.
    private func contrastRatio(_ first: Color, _ second: Color) -> CGFloat {
        let l1 = wcagLuminance(first)
        let l2 = wcagLuminance(second)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func wcagLuminance(_ color: Color) -> CGFloat {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(nsColor.redComponent)
            + 0.7152 * linear(nsColor.greenComponent)
            + 0.0722 * linear(nsColor.blueComponent)
    }
}

private extension SpaceLensPalette {
    /// Convenience for the sibling-distinctness test: resolve the base color for
    /// a child at `index` of `count` via the same even hue fan the treemap uses.
    static func baseColor(for node: DiskNode, hueIndex index: Int, of count: Int) -> Color {
        baseColor(hue: hue(forChildAt: index, of: count), for: node)
    }
}
