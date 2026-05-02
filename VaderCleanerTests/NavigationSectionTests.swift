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

    func test_eachSection_hasValidSFSymbol() {
        for section in NavigationSection.allCases {
            let image = NSImage(systemSymbolName: section.icon, accessibilityDescription: nil)
            XCTAssertNotNil(
                image,
                "Expected valid SF Symbol '\(section.icon)' for section: \(section)"
            )
        }
    }
}
