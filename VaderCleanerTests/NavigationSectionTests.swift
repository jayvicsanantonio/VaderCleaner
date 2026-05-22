// NavigationSectionTests.swift
// Tests that verify NavigationSection enum structure and SF Symbol validity.

import XCTest
import AppKit
@testable import VaderCleaner

final class NavigationSectionTests: XCTestCase {

    func test_allCasesCount_is11() {
        XCTAssertEqual(NavigationSection.allCases.count, 11)
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
            .extensions: "sidebar.extensions",
            .appUninstaller: "sidebar.appUninstaller",
            .appUpdater: "sidebar.appUpdater",
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
            .extensions: "section.extensions.scan",
            .appUninstaller: "section.appUninstaller.scan",
            .appUpdater: "section.appUpdater.scan",
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
            .extensions: false,
            .appUninstaller: false,
            .appUpdater: false,
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

    func test_transitionDirection_toLowerRailRow_isDown() {
        // Smart Scan sits above System Junk in the rail, so moving the
        // selection to System Junk sends the detail content downward.
        XCTAssertEqual(
            NavigationSection.smartScan.transitionDirection(to: .systemJunk),
            .down
        )
    }

    func test_transitionDirection_toHigherRailRow_isUp() {
        // The reverse move — back up to a higher row — travels upward.
        XCTAssertEqual(
            NavigationSection.systemJunk.transitionDirection(to: .smartScan),
            .up
        )
    }

    func test_transitionDirection_acrossMultipleRows_followsRailOrder() {
        // Distance doesn't matter, only order: jumping from the first row to
        // the last is still `.down`, and the return jump is `.up`.
        XCTAssertEqual(
            NavigationSection.smartScan.transitionDirection(to: .healthMonitor),
            .down
        )
        XCTAssertEqual(
            NavigationSection.healthMonitor.transitionDirection(to: .smartScan),
            .up
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
}
