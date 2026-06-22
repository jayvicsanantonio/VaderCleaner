// ScanCategoryTests.swift
// Tests that every ScanCategory case has a non-empty display name and stable raw value for persistence.

import XCTest
@testable import VaderCleaner

/// Pins the public surface of `ScanCategory`.
///
/// Categories are persisted (e.g. as raw values in user preferences) and
/// surfaced in the UI by `displayName`. A future refactor that drops a case
/// or renames a raw value would silently break stored state — these tests
/// catch that.
final class ScanCategoryTests: XCTestCase {

    /// `allCases` is the source of truth for the System Junk preview list and
    /// the Large & Old Files scanner's category set. Pinning the count means
    /// any future case addition is a deliberate test update, not a silent
    /// expansion that breaks downstream UI assumptions.
    func test_allCases_containsAllExpectedCategories() {
        XCTAssertEqual(ScanCategory.allCases.count, 12)
        XCTAssertTrue(ScanCategory.allCases.contains(.systemCache))
        XCTAssertTrue(ScanCategory.allCases.contains(.userCache))
        XCTAssertTrue(ScanCategory.allCases.contains(.systemLogs))
        XCTAssertTrue(ScanCategory.allCases.contains(.userLogs))
        XCTAssertTrue(ScanCategory.allCases.contains(.languageFiles))
        XCTAssertTrue(ScanCategory.allCases.contains(.mailAttachments))
        XCTAssertTrue(ScanCategory.allCases.contains(.iosBackups))
        XCTAssertTrue(ScanCategory.allCases.contains(.trash))
        XCTAssertTrue(ScanCategory.allCases.contains(.largeFile))
        XCTAssertTrue(ScanCategory.allCases.contains(.oldFile))
        XCTAssertTrue(ScanCategory.allCases.contains(.xcodeJunk))
        XCTAssertTrue(ScanCategory.allCases.contains(.documentVersions))
    }

    /// Every case must produce a non-empty user-facing label so the UI never
    /// renders a blank row.
    func test_displayName_nonEmptyForEveryCase() {
        for category in ScanCategory.allCases {
            XCTAssertFalse(
                category.displayName.isEmpty,
                "Display name was empty for \(category)"
            )
        }
    }

    /// Raw values back persistence (preferences, JSON-encoded scan reports).
    /// Pinning them here guarantees a rename is accompanied by a test update.
    func test_rawValues_areStable() {
        XCTAssertEqual(ScanCategory.systemCache.rawValue, "systemCache")
        XCTAssertEqual(ScanCategory.userCache.rawValue, "userCache")
        XCTAssertEqual(ScanCategory.trash.rawValue, "trash")
        XCTAssertEqual(ScanCategory.largeFile.rawValue, "largeFile")
        XCTAssertEqual(ScanCategory.xcodeJunk.rawValue, "xcodeJunk")
        XCTAssertEqual(ScanCategory.documentVersions.rawValue, "documentVersions")
    }
}
