// NavigationSectionTests.swift
// Tests that verify NavigationSection enum structure and SF Symbol validity.

import XCTest
import AppKit
@testable import VaderCleaner

final class NavigationSectionTests: XCTestCase {

    func test_allCasesCount_is9() {
        XCTAssertEqual(NavigationSection.allCases.count, 9)
    }

    func test_firstCase_isSmartScan() {
        XCTAssertEqual(NavigationSection.allCases.first, .smartScan)
    }

    func test_eachSection_hasNonEmptyTitle() {
        for section in NavigationSection.allCases {
            XCTAssertFalse(
                section.title.isEmpty,
                "Expected non-empty title for section: \(section)"
            )
        }
    }

    func test_accessibilityIdentifiers_areStableAndPinned() {
        let expected: [NavigationSection: String] = [
            .smartScan: "sidebar.smartScan",
            .systemJunk: "sidebar.systemJunk",
            .largeOldFiles: "sidebar.largeOldFiles",
            .spaceLens: "sidebar.spaceLens",
            .malwareRemoval: "sidebar.malwareRemoval",
            .privacy: "sidebar.privacy",
            .applications: "sidebar.applications",
            .optimization: "sidebar.optimization",
            .healthMonitor: "sidebar.healthMonitor",
        ]
        for section in NavigationSection.allCases {
            XCTAssertEqual(
                section.accessibilityIdentifier,
                expected[section],
                "Sidebar identifier for \(section) drifted — update the UI-test locators too"
            )
        }
    }

    func test_accessibilityIdentifiers_areUnique() {
        let ids = NavigationSection.allCases.map(\.accessibilityIdentifier)
        XCTAssertEqual(Set(ids).count, ids.count, "Sidebar identifiers must be unique")
    }

    func test_scanAccessibilityIdentifiers_areStableAndPinned() {
        let expected: [NavigationSection: String] = [
            .smartScan: "section.smartScan.scan",
            .systemJunk: "section.systemJunk.scan",
            .largeOldFiles: "section.largeOldFiles.scan",
            .spaceLens: "section.spaceLens.scan",
            .malwareRemoval: "section.malwareRemoval.scan",
            .privacy: "section.privacy.scan",
            .applications: "section.applications.scan",
            .optimization: "section.optimization.scan",
            .healthMonitor: "section.healthMonitor.scan",
        ]
        for section in NavigationSection.allCases {
            XCTAssertEqual(
                section.scanAccessibilityIdentifier,
                expected[section],
                "Scan identifier for \(section) drifted — update the UI-test locators too"
            )
        }
    }

    func test_scanAccessibilityIdentifiers_areUnique() {
        let ids = NavigationSection.allCases.map(\.scanAccessibilityIdentifier)
        XCTAssertEqual(Set(ids).count, ids.count, "Scan identifiers must be unique")
    }

    func test_requiresFullDiskAccess_isPinned() {
        // The reminder card surfaces on a section's intro only when its scan
        // actually needs Full Disk Access. Pinned per case so a future
        // section can't silently slip through with the wrong default.
        let expected: [NavigationSection: Bool] = [
            .smartScan: true,        // composes System Junk + Malware
            .systemJunk: true,       // /Library/Caches, /Library/Logs, mail
            .largeOldFiles: true,    // walks ~/Library
            .spaceLens: true,        // home directory walk
            .malwareRemoval: true,   // ClamAV scan
            .optimization: false,    // launchctl / login items / RAM
            .privacy: true,          // Safari data lives in TCC-protected paths
            .applications: false,    // app discovery + update checks; no FDA-gated paths
            .healthMonitor: false,
        ]
        for section in NavigationSection.allCases {
            XCTAssertEqual(
                section.requiresFullDiskAccess,
                expected[section],
                "requiresFullDiskAccess for \(section) drifted — reclassify here intentionally."
            )
        }
    }

    func test_transitionDirection_toLowerRailRow_isUp() {
        // Smart Scan sits above System Junk in the rail. The transition
        // reads as a scroll toward the lower row: the outgoing section
        // exits the top and the incoming follows up from the bottom, so
        // the content travels `.up`.
        XCTAssertEqual(
            NavigationSection.smartScan.transitionDirection(to: .systemJunk),
            .up
        )
    }

    func test_transitionDirection_toHigherRailRow_isDown() {
        // The reverse move — back up to a higher row — mirrors the scroll
        // in the other direction, sending content `.down`.
        XCTAssertEqual(
            NavigationSection.systemJunk.transitionDirection(to: .smartScan),
            .down
        )
    }

    func test_transitionDirection_acrossMultipleRows_followsRailOrder() {
        // Distance doesn't matter, only order: jumping from the first row to
        // the last still scrolls `.up`, and the return jump scrolls `.down`.
        XCTAssertEqual(
            NavigationSection.smartScan.transitionDirection(to: .healthMonitor),
            .up
        )
        XCTAssertEqual(
            NavigationSection.healthMonitor.transitionDirection(to: .smartScan),
            .down
        )
    }

    func test_eachSection_hasValidSFSymbol() throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("SF Symbol validation requires macOS 14.0 (the app's minimum deployment target)")
        }
        for section in NavigationSection.allCases {
            let image = NSImage(systemSymbolName: section.icon, accessibilityDescription: nil)
            XCTAssertNotNil(
                image,
                "Expected valid SF Symbol '\(section.icon)' for section: \(section)"
            )
        }
    }

    /// Every section ships a monochrome rail glyph named after its case +
    /// "Mono" — the scannable ones derived from hero art, Health Monitor
    /// authored procedurally.
    func test_railIconAssetName_isPinned() {
        for section in NavigationSection.allCases {
            XCTAssertEqual(
                section.railIconAssetName,
                "\(String(describing: section))Mono",
                "Rail glyph name for \(section) must be its case name + \"Mono\""
            )
        }
    }

    /// Each declared rail glyph must resolve to a real image in the app
    /// bundle's asset catalog — guards against drift between the declarations
    /// and the imagesets produced by Scripts/generate-rail-glyphs.swift.
    func test_eachRailIconAssetName_resolvesToAnImageInTheBundle() throws {
        let bundle = Bundle.main
        for section in NavigationSection.allCases {
            guard let asset = section.railIconAssetName else { continue }
            XCTAssertNotNil(
                NSImage(named: asset) ?? bundle.image(forResource: asset),
                "Asset catalog is missing rail glyph \"\(asset)\" for \(section)"
            )
        }
    }
}
