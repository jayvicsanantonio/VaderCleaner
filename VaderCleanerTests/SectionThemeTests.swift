// SectionThemeTests.swift
// Pins the per-section color identity contract: every section has a theme, and the accents are distinct so the window visibly retints as the user moves between sections.

import XCTest
import SwiftUI
@testable import VaderCleaner

final class SectionThemeTests: XCTestCase {

    func test_everySection_hasATheme() {
        // The window backdrop is keyed to the section, so every case — not
        // just the scannable ones — must carry a theme.
        for section in NavigationSection.allCases {
            let theme = section.theme
            XCTAssertNotEqual(
                theme.accent,
                .clear,
                "Section \(section) must have a visible accent"
            )
        }
    }

    func test_accentsAreDistinctAcrossSections() {
        // A distinct accent per section is what makes the window visibly
        // retint on navigation — the whole point of the per-section backdrop.
        let accents = NavigationSection.allCases.map(\.theme.accent)
        XCTAssertEqual(
            Set(accents).count,
            NavigationSection.allCases.count,
            "Each section must have a distinct accent so navigation retints the UI"
        )
    }

    func test_backdropGradient_hasTwoDistinctStops() {
        // Top and bottom of the window gradient must differ or the backdrop
        // reads as a flat fill instead of the reference's dark-to-rich ramp.
        for section in NavigationSection.allCases {
            let theme = section.theme
            XCTAssertNotEqual(
                theme.backdropTop,
                theme.backdropBottom,
                "Section \(section) backdrop must ramp between two distinct tones"
            )
        }
    }

    func test_iconAccent_matchesThemeAccentExceptHealthMonitor() {
        // The icon-glyph / active-rail tint equals the chrome accent for every
        // section except Health Monitor, whose pink hero family overrides it.
        for section in NavigationSection.allCases where section != .healthMonitor {
            XCTAssertEqual(
                section.iconAccent, section.theme.accent,
                "\(section) icon accent must track its chrome accent"
            )
        }
        XCTAssertNotEqual(
            NavigationSection.healthMonitor.iconAccent,
            NavigationSection.healthMonitor.theme.accent,
            "Health Monitor's icon accent must diverge (pink) from its blue chrome accent"
        )
    }

    func test_accentDiffersFromBackdrop() {
        // The accent blooms over the backdrop; if it equalled a backdrop stop
        // the hero glow and Scan disc would vanish into the background.
        for section in NavigationSection.allCases {
            let theme = section.theme
            XCTAssertNotEqual(theme.accent, theme.backdropTop, "\(section) accent must stand out from backdropTop")
            XCTAssertNotEqual(theme.accent, theme.backdropBottom, "\(section) accent must stand out from backdropBottom")
        }
    }
}
