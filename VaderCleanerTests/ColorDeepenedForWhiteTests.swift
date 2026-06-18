// ColorDeepenedForWhiteTests.swift
// Pins the contrast contract for Color.deepenedForWhite: bright section fills deepen enough to carry white text, while already-dark fills pass through unchanged.

import XCTest
import SwiftUI
import AppKit
@testable import VaderCleaner

final class ColorDeepenedForWhiteTests: XCTestCase {

    /// WCAG relative luminance (0…1) of a resolved sRGB colour.
    private func luminance(_ color: Color) -> Double {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(white: 0, alpha: 1)
        func channel(_ v: CGFloat) -> Double {
            let value = Double(v)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    /// Contrast ratio of `color` against white — the foreground these fills carry.
    private func contrastWithWhite(_ color: Color) -> Double {
        (1.0 + 0.05) / (luminance(color) + 0.05)
    }

    /// The two section accents bright enough to need deepening must drop to a
    /// fill that carries white text legibly. These are the sections that
    /// previously flipped their label/glyph to black.
    func test_brightAccents_areDeepenedEnoughForWhiteText() {
        for section in [NavigationSection.systemJunk, .largeOldFiles] {
            let accent = section.theme.accent
            XCTAssertLessThan(
                contrastWithWhite(accent), 3.0,
                "\(section) accent should start too bright to carry white"
            )
            let deepened = accent.deepenedForWhite
            XCTAssertGreaterThanOrEqual(
                contrastWithWhite(deepened), 4.0,
                "\(section) deepened fill must carry white text legibly"
            )
        }
    }

    /// Every accent already dark enough for white must be returned identical, so
    /// the seven non-bright sections stay pixel-for-pixel unchanged.
    func test_darkAccents_passThroughUnchanged() {
        let darkSections: [NavigationSection] = [
            .smartScan, .spaceLens, .malwareRemoval,
            .optimization, .privacy, .applications, .healthMonitor,
        ]
        for section in darkSections {
            let accent = section.theme.accent
            XCTAssertEqual(
                accent.deepenedForWhite, accent,
                "\(section) accent is already white-legible and must not change"
            )
        }
    }
}
