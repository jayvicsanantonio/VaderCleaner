// PrivacyCategoryTests.swift
// Verifies the PrivacyCategory enum's stable raw values and per-case display labels used in the Privacy preview rows.

import XCTest
@testable import VaderCleaner

final class PrivacyCategoryTests: XCTestCase {

    /// All five categories from the spec must be present. The Privacy UI
    /// iterates this list to render checkboxes, so a missing case would
    /// silently strip a category from the user's options.
    func test_allCases_containsEveryExpectedCategory() {
        let cases = Set(PrivacyCategory.allCases)
        XCTAssertEqual(cases, [.history, .downloads, .cookies, .cache, .savedForms])
    }

    /// Raw values are persisted in view-model state and tests pin them so a
    /// rename doesn't silently invalidate stored selections.
    func test_rawValues_areStable() {
        XCTAssertEqual(PrivacyCategory.history.rawValue,    "history")
        XCTAssertEqual(PrivacyCategory.downloads.rawValue,  "downloads")
        XCTAssertEqual(PrivacyCategory.cookies.rawValue,    "cookies")
        XCTAssertEqual(PrivacyCategory.cache.rawValue,      "cache")
        XCTAssertEqual(PrivacyCategory.savedForms.rawValue, "savedForms")
    }

    /// Every category renders a non-empty label in the preview list.
    func test_displayName_isNonEmptyForEveryCase() {
        for category in PrivacyCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty,
                           "Missing displayName for \(category)")
        }
    }
}
