// AppVendorTests.swift
// Tests the AppVendor reverse-DNS classifier that drives the Applications Manager "Vendors" facet — known prefixes map to named vendors, everything else falls back to Other.

import Testing
@testable import VaderCleanerCore

@Suite
struct AppVendorTests {

    /// Apple bundle IDs classify as Apple regardless of the trailing component.
    @Test
    func of_applePrefix_isApple() {
        #expect(AppVendor.of(bundleID: "com.apple.Safari") == .apple)
        #expect(AppVendor.of(bundleID: "com.apple.dt.Xcode") == .apple)
    }

    /// Google bundle IDs classify as Google.
    @Test
    func of_googlePrefix_isGoogle() {
        #expect(AppVendor.of(bundleID: "com.google.Chrome") == .google)
    }

    /// Microsoft bundle IDs classify as Microsoft.
    @Test
    func of_microsoftPrefix_isMicrosoft() {
        #expect(AppVendor.of(bundleID: "com.microsoft.VSCode") == .microsoft)
    }

    /// Matching is case-insensitive so a vendor isn't missed on casing alone.
    @Test
    func of_isCaseInsensitive() {
        #expect(AppVendor.of(bundleID: "COM.APPLE.Finder") == .apple)
    }

    /// A prefix only matches on a component boundary, so a lookalike vendor
    /// (e.g. "com.appleseed.app") is NOT misread as Apple.
    @Test
    func of_lookalikePrefix_isNotMisclassified() {
        #expect(AppVendor.of(bundleID: "com.appleseed.App") != .apple)
    }

    /// An unknown vendor falls back to Other rather than failing.
    @Test
    func of_unknownPrefix_isOther() {
        #expect(AppVendor.of(bundleID: "io.unknownvendor.App") == .other)
        #expect(AppVendor.of(bundleID: "net.somethingelse.Tool") == .other)
        #expect(AppVendor.of(bundleID: "") == .other)
    }

    /// The display title is the human-readable vendor name.
    @Test
    func title() {
        #expect(AppVendor.apple.title == "Apple")
        #expect(AppVendor.other.title == "Other")
    }
}
