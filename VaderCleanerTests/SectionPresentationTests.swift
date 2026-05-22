// SectionPresentationTests.swift
// Pins the scan-centric section metadata contract: which sections are scannable and each scannable section's presentation content.

import XCTest
import AppKit
import SwiftUI
@testable import VaderCleaner

final class SectionPresentationTests: XCTestCase {

    /// The six sections that drive a scan/load and therefore get the unified
    /// intro screen + floating Scan button. Pinned here so a drift in
    /// `isScannable` or `SectionPresentation.for(_:)` fails loudly.
    private let scannableSections: Set<NavigationSection> = [
        .smartScan, .systemJunk, .largeOldFiles,
        .spaceLens, .malwareRemoval, .optimization,
    ]

    func test_isScannable_isTrueForExactlyTheSixScannableSections() {
        for section in NavigationSection.allCases {
            let expected = scannableSections.contains(section)
            XCTAssertEqual(
                section.isScannable,
                expected,
                "isScannable for \(section) should be \(expected)"
            )
        }
    }

    func test_isScannable_countIsExactlySix() {
        let count = NavigationSection.allCases.filter(\.isScannable).count
        XCTAssertEqual(count, 6, "Exactly six sections must be scannable")
    }

    func test_presentationFor_isNonNilForScannableAndNilOtherwise() {
        for section in NavigationSection.allCases {
            let presentation = SectionPresentation.for(section)
            if scannableSections.contains(section) {
                XCTAssertNotNil(
                    presentation,
                    "Expected presentation for scannable section \(section)"
                )
            } else {
                XCTAssertNil(
                    presentation,
                    "Non-scannable section \(section) must have no presentation"
                )
            }
        }
    }

    func test_smartScanFeatures_areTheThreeOrchestratedModulesInOrder() throws {
        let presentation = try XCTUnwrap(SectionPresentation.for(.smartScan))
        let orchestrated: [NavigationSection] = [.systemJunk, .malwareRemoval, .optimization]
        XCTAssertEqual(
            presentation.features.map(\.title),
            orchestrated.map(\.title),
            "Smart Scan must surface its real orchestrated modules, in order"
        )
        XCTAssertEqual(
            presentation.features.map(\.symbol),
            orchestrated.map(\.icon),
            "Smart Scan feature icons must track the real sections' icons"
        )
    }

    func test_everyScannablePresentation_hasNonEmptyTaglineAndFeatures() throws {
        for section in scannableSections {
            let presentation = try XCTUnwrap(
                SectionPresentation.for(section),
                "Missing presentation for \(section)"
            )
            XCTAssertFalse(
                presentation.tagline.isEmpty,
                "Tagline must be non-empty for \(section)"
            )
            XCTAssertFalse(
                presentation.heroSymbol.isEmpty,
                "Hero symbol must be non-empty for \(section)"
            )
            XCTAssertFalse(
                presentation.features.isEmpty,
                "Feature list must be non-empty for \(section)"
            )
            for feature in presentation.features {
                XCTAssertFalse(
                    feature.symbol.isEmpty,
                    "Feature symbol must be non-empty for \(section)"
                )
                XCTAssertFalse(
                    feature.title.isEmpty,
                    "Feature title must be non-empty for \(section)"
                )
            }
        }
    }

    /// Every scannable section's intro accent must be the single Vader crimson —
    /// the app's one brand accent. A section added with a stray accent (or an
    /// existing one drifting back to a per-section color) fails loudly here.
    func test_everyScannablePresentationAccent_isVaderCrimson() throws {
        for section in scannableSections {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            XCTAssertEqual(
                presentation.accent,
                .vaderCrimson,
                "Section \(section) must use the unified crimson accent"
            )
        }
    }

    func test_everyPresentationSymbol_isAValidSFSymbol() throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("SF Symbol validation requires macOS 14.0 (the app's minimum deployment target)")
        }
        for section in scannableSections {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let symbols = [presentation.heroSymbol] + presentation.features.map(\.symbol)
            for symbol in symbols {
                XCTAssertNotNil(
                    NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                    "Invalid SF Symbol '\(symbol)' in presentation for \(section)"
                )
            }
        }
    }
}
