// SectionIntroViewTests.swift
// Pins the SectionIntroView contract: it builds from every scannable section's real presentation and exposes the stable section.intro / per-feature accessibility identifiers.

import XCTest
import SwiftUI
@testable import VaderCleaner

@MainActor
final class SectionIntroViewTests: XCTestCase {

    /// The seven scannable sections, each paired with the per-section
    /// accessibility-id slug it must derive from its `NavigationSection` case
    /// name (locale-independent). Hardcoded — not re-derived through the
    /// view's own slug helper — so a regression in that helper fails this
    /// test loudly instead of silently agreeing.
    private let expectedSlugs: [NavigationSection: String] = [
        .smartScan: "smartscan",
        .systemJunk: "systemjunk",
        .largeOldFiles: "largeoldfiles",
        .spaceLens: "spacelens",
        .malwareRemoval: "malwareremoval",
        .optimization: "optimization",
        .privacy: "privacy",
    ]

    func test_buildsFromEveryScannableSectionPresentation() throws {
        for section in NavigationSection.allCases where section.isScannable {
            let presentation = try XCTUnwrap(
                SectionPresentation.for(section),
                "Scannable section \(section) must have a presentation"
            )
            let view = SectionIntroView(presentation: presentation, section: section)

            XCTAssertEqual(
                view.title,
                section.title,
                "SectionIntroView must surface the title it was given for \(section)"
            )
            XCTAssertEqual(
                view.presentation.features.count,
                presentation.features.count,
                "SectionIntroView must carry the presentation it was given for \(section)"
            )
        }
    }

    func test_rootAccessibilityIdentifierIsStable() throws {
        for section in NavigationSection.allCases where section.isScannable {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let view = SectionIntroView(presentation: presentation, section: section)

            XCTAssertEqual(
                view.rootAccessibilityIdentifier,
                "section.intro",
                "Every section's intro must share the stable root identifier"
            )
        }
    }

    func test_perSectionAccessibilityIdentifierMatchesExpectedSlug() throws {
        for section in NavigationSection.allCases where section.isScannable {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let view = SectionIntroView(presentation: presentation, section: section)
            let expectedSlug = try XCTUnwrap(
                expectedSlugs[section],
                "Missing expected slug for \(section) — update the test map"
            )

            XCTAssertEqual(
                view.sectionAccessibilityIdentifier,
                "section.intro.\(expectedSlug)",
                "Per-section identifier for \(section) drifted from its pinned slug"
            )
        }
    }

    func test_featureCountMatchesPresentation() throws {
        for section in NavigationSection.allCases where section.isScannable {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let view = SectionIntroView(presentation: presentation, section: section)

            XCTAssertEqual(
                view.featureCount,
                presentation.features.count,
                "featureCount must equal presentation.features.count for \(section)"
            )
            XCTAssertGreaterThan(
                view.featureCount,
                0,
                "Every scannable section ships at least one descriptive feature row"
            )
        }
    }

    func test_reminderShows_whenSectionRequiresFDAAndAccessIsMissing() throws {
        // The reminder card surfaces on the intro of every FDA-sensitive
        // section whenever Full Disk Access has not been granted. Tested via
        // the view's pure predicate so we don't need to render the body.
        for section in NavigationSection.allCases where section.isScannable && section.requiresFullDiskAccess {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let view = SectionIntroView(presentation: presentation, section: section)

            XCTAssertTrue(
                view.shouldShowFullDiskAccessReminder(hasFullDiskAccess: false),
                "\(section) requires FDA — the reminder must show when access is missing"
            )
        }
    }

    func test_reminderHides_whenFullDiskAccessIsGranted() throws {
        // Granting access takes the card away on the next state flip, so the
        // intro returns to its uncluttered landing.
        for section in NavigationSection.allCases where section.isScannable {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let view = SectionIntroView(presentation: presentation, section: section)

            XCTAssertFalse(
                view.shouldShowFullDiskAccessReminder(hasFullDiskAccess: true),
                "\(section) must not show the reminder once Full Disk Access is granted"
            )
        }
    }

    func test_reminderHides_whenSectionDoesNotRequireFDA() throws {
        // Sections whose scans don't read FDA-gated paths never warn, even
        // when access is missing — the reminder is reserved for cases where
        // missing FDA actually yields empty or incomplete results.
        for section in NavigationSection.allCases
            where section.isScannable && !section.requiresFullDiskAccess
        {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let view = SectionIntroView(presentation: presentation, section: section)

            XCTAssertFalse(
                view.shouldShowFullDiskAccessReminder(hasFullDiskAccess: false),
                "\(section) does not require FDA — the reminder must stay hidden"
            )
        }
    }

    func test_eachFeatureExposesItsIndexedAccessibilityIdentifier() throws {
        for section in NavigationSection.allCases where section.isScannable {
            let presentation = try XCTUnwrap(SectionPresentation.for(section))
            let view = SectionIntroView(presentation: presentation, section: section)

            for index in 0..<view.featureCount {
                XCTAssertEqual(
                    view.featureAccessibilityIdentifier(at: index),
                    "section.intro.feature.\(index)",
                    "Feature row \(index) of \(section) must expose its indexed identifier"
                )
            }
        }
    }
}
