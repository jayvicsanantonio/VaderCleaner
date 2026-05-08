// BrowserTests.swift
// Verifies the Browser enum's stable identifiers and per-case bundle / display metadata used by detection and the Privacy UI.

import XCTest
@testable import VaderCleaner

final class BrowserTests: XCTestCase {

    /// Every browser case must exist in `allCases`. The Privacy feature
    /// scans this list to drive detection — a missing case would silently
    /// hide a browser from the user, which is worse than a wrong path.
    func test_allCases_containsEveryExpectedBrowser() {
        let cases = Set(Browser.allCases)
        XCTAssertEqual(cases, [
            .safari, .chrome, .firefox, .brave, .arc, .opera, .edge
        ])
    }

    /// Bundle identifiers are a stable contract — they're keyed off when
    /// users have multiple Chromium-based browsers installed and the path
    /// provider keys data dirs by them. A typo here surfaces as silent
    /// mis-detection in the field, so pin them in tests.
    func test_bundleIdentifier_matchesShippedBundles() {
        XCTAssertEqual(Browser.safari.bundleIdentifier,  "com.apple.Safari")
        XCTAssertEqual(Browser.chrome.bundleIdentifier,  "com.google.Chrome")
        XCTAssertEqual(Browser.firefox.bundleIdentifier, "org.mozilla.firefox")
        XCTAssertEqual(Browser.brave.bundleIdentifier,   "com.brave.Browser")
        XCTAssertEqual(Browser.arc.bundleIdentifier,     "company.thebrowser.Browser")
        XCTAssertEqual(Browser.opera.bundleIdentifier,   "com.operasoftware.Opera")
        XCTAssertEqual(Browser.edge.bundleIdentifier,    "com.microsoft.edgemac")
    }

    /// `appBundleName` drives `/Applications/<name>.app` existence checks in
    /// `BrowserDetector`. The display name (e.g. "Brave Browser") and the
    /// bundle filename (`Brave Browser.app`) diverge enough across browsers
    /// to be worth pinning per case.
    func test_appBundleName_matchesShippedBundles() {
        XCTAssertEqual(Browser.safari.appBundleName,  "Safari.app")
        XCTAssertEqual(Browser.chrome.appBundleName,  "Google Chrome.app")
        XCTAssertEqual(Browser.firefox.appBundleName, "Firefox.app")
        XCTAssertEqual(Browser.brave.appBundleName,   "Brave Browser.app")
        XCTAssertEqual(Browser.arc.appBundleName,     "Arc.app")
        XCTAssertEqual(Browser.opera.appBundleName,   "Opera.app")
        XCTAssertEqual(Browser.edge.appBundleName,    "Microsoft Edge.app")
    }

    /// The display name is shown in the Privacy UI; non-empty for every case
    /// keeps the rendered list from showing a blank row.
    func test_displayName_isNonEmptyForEveryCase() {
        for browser in Browser.allCases {
            XCTAssertFalse(browser.displayName.isEmpty,
                           "Missing displayName for \(browser)")
        }
    }
}
