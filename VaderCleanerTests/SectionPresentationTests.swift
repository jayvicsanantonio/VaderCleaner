// SectionPresentationTests.swift
// Pins the scan-centric section metadata contract: which sections are scannable and each scannable section's presentation content.

import XCTest
import AppKit
import SwiftUI
@testable import VaderCleaner

final class SectionPresentationTests: XCTestCase {

    /// The eight sections that drive a scan/load and therefore get the unified
    /// intro screen + floating Scan button. Pinned here so a drift in
    /// `isScannable` or `SectionPresentation.for(_:)` fails loudly.
    private let scannableSections: Set<NavigationSection> = [
        .smartScan, .systemJunk, .largeOldFiles,
        .spaceLens, .malwareRemoval, .optimization, .privacy,
        .applications,
    ]

    /// The scannable sections that ship a bespoke USDZ 3D hero model named
    /// after their enum case. `.applications` is intentionally excluded — it
    /// uses the SF Symbol hero fallback (`heroModelName: nil`) until a model
    /// is designed for it.
    private let sectionsWithHeroModel: Set<NavigationSection> = [
        .smartScan, .systemJunk, .largeOldFiles,
        .spaceLens, .malwareRemoval, .optimization, .privacy,
    ]

    func test_isScannable_isTrueForExactlyTheEightScannableSections() {
        for section in NavigationSection.allCases {
            let expected = scannableSections.contains(section)
            XCTAssertEqual(
                section.isScannable,
                expected,
                "isScannable for \(section) should be \(expected)"
            )
        }
    }

    func test_isScannable_countIsExactlyEight() {
        let count = NavigationSection.allCases.filter(\.isScannable).count
        XCTAssertEqual(count, 8, "Exactly eight sections must be scannable")
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

    /// Every scannable section's intro accent must mirror its
    /// `NavigationSection.theme` accent, so the hero, feature badges, and
    /// floating Scan disc match the per-section window backdrop. A section that
    /// hardcodes a stray accent instead of its theme fails loudly here.
    func test_everyScannablePresentationAccent_matchesSectionTheme() throws {
        for section in scannableSections {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            XCTAssertEqual(
                presentation.accent,
                section.theme.accent,
                "Section \(section)'s presentation accent must mirror its theme accent"
            )
        }
    }

    /// Every scannable section must declare the USDZ hero model that matches
    /// its enum case name (e.g. `.smartScan` → `"smartScan"`). The naming is
    /// the contract that lets `SectionIntroView` resolve the right asset
    /// without a per-section switch.
    func test_everyModelBearingPresentation_hasHeroModelNameMatchingSectionCase() throws {
        for section in sectionsWithHeroModel {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            XCTAssertEqual(
                presentation.heroModelName,
                String(describing: section),
                "Section \(section) must declare heroModelName \"\(String(describing: section))\""
            )
        }
    }

    /// Sections that intentionally have no USDZ hero must declare
    /// `heroModelName: nil` so `SectionIntroView` takes the SF Symbol fallback
    /// rather than trying to load a missing model.
    func test_sectionsWithoutHeroModel_declareNilModelName() throws {
        for section in scannableSections.subtracting(sectionsWithHeroModel) {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            XCTAssertNil(
                presentation.heroModelName,
                "Section \(section) ships no USDZ, so heroModelName must be nil"
            )
        }
    }

    /// The declared hero model name must resolve to a real USDZ in the app
    /// bundle — guards against drift between `SectionPresentation` declarations
    /// and the files actually shipped in `Resources/Models/`.
    func test_everyHeroModelName_resolvesToAUsdzInTheBundle() throws {
        // Unit tests run with the VaderCleaner app as the test host
        // (TEST_HOST in the test target's build settings), so Bundle.main
        // here is the host app's bundle — the same one Model3D(named:)
        // queries at runtime.
        let bundle = Bundle.main
        for section in sectionsWithHeroModel {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let modelName = try XCTUnwrap(
                presentation.heroModelName,
                "Missing heroModelName for \(section)"
            )
            XCTAssertNotNil(
                bundle.url(forResource: modelName, withExtension: "usdz"),
                "Bundle is missing Resources/Models/\(modelName).usdz for \(section)"
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
