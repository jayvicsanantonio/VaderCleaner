// AppVendorTests.swift
// Tests the AppVendor reverse-DNS classifier that drives the Applications Manager "Vendors" facet — known prefixes map to named vendors, everything else falls back to Other.

import XCTest
@testable import VaderCleaner

final class AppVendorTests: XCTestCase {

    /// Apple bundle IDs classify as Apple regardless of the trailing component.
    func test_of_applePrefix_isApple() {
        XCTAssertEqual(AppVendor.of(bundleID: "com.apple.Safari"), .apple)
        XCTAssertEqual(AppVendor.of(bundleID: "com.apple.dt.Xcode"), .apple)
    }

    /// Google bundle IDs classify as Google.
    func test_of_googlePrefix_isGoogle() {
        XCTAssertEqual(AppVendor.of(bundleID: "com.google.Chrome"), .google)
    }

    /// Microsoft bundle IDs classify as Microsoft.
    func test_of_microsoftPrefix_isMicrosoft() {
        XCTAssertEqual(AppVendor.of(bundleID: "com.microsoft.VSCode"), .microsoft)
    }

    /// Matching is case-insensitive so a vendor isn't missed on casing alone.
    func test_of_isCaseInsensitive() {
        XCTAssertEqual(AppVendor.of(bundleID: "COM.APPLE.Finder"), .apple)
    }

    /// A prefix only matches on a component boundary, so a lookalike vendor
    /// (e.g. "com.appleseed.app") is NOT misread as Apple.
    func test_of_lookalikePrefix_isNotMisclassified() {
        XCTAssertNotEqual(AppVendor.of(bundleID: "com.appleseed.App"), .apple)
    }

    /// An unknown vendor falls back to Other rather than failing.
    func test_of_unknownPrefix_isOther() {
        XCTAssertEqual(AppVendor.of(bundleID: "io.unknownvendor.App"), .other)
        XCTAssertEqual(AppVendor.of(bundleID: "net.somethingelse.Tool"), .other)
        XCTAssertEqual(AppVendor.of(bundleID: ""), .other)
    }

    /// The display title is the human-readable vendor name.
    func test_title() {
        XCTAssertEqual(AppVendor.apple.title, "Apple")
        XCTAssertEqual(AppVendor.other.title, "Other")
    }
}
