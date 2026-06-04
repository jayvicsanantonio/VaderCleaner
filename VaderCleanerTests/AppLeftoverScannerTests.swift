// AppLeftoverScannerTests.swift
// Pins DefaultAppLeftoverScanner's pure matching helpers and drives the full scan against temp ~/Library fixtures — covering per-root bundle-ID derivation, the reverse-DNS / Apple / installed-sub-ID guards, grouping across roots, and sizing. Hermetic.

import XCTest
@testable import VaderCleaner

final class AppLeftoverScannerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()
    }

    override func tearDown() {
        if let tempRoot { TestHelpers.tearDownTempDirectory(tempRoot) }
        tempRoot = nil
        super.tearDown()
    }

    private func makeDir(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Pure helpers

    func test_looksLikeBundleID() {
        XCTAssertTrue(DefaultAppLeftoverScanner.looksLikeBundleID("com.acme.App"))
        XCTAssertTrue(DefaultAppLeftoverScanner.looksLikeBundleID("com.acme.App-Beta"))
        XCTAssertTrue(DefaultAppLeftoverScanner.looksLikeBundleID("com.apple.dt.Xcode"))
        // Too few components / human names / malformed.
        XCTAssertFalse(DefaultAppLeftoverScanner.looksLikeBundleID("Google"))
        XCTAssertFalse(DefaultAppLeftoverScanner.looksLikeBundleID("com.acme"))
        XCTAssertFalse(DefaultAppLeftoverScanner.looksLikeBundleID("com..App"))
        XCTAssertFalse(DefaultAppLeftoverScanner.looksLikeBundleID("com.acme.App!"))
    }

    func test_isSystemBundleID() {
        XCTAssertTrue(DefaultAppLeftoverScanner.isSystemBundleID("com.apple.finder"))
        XCTAssertTrue(DefaultAppLeftoverScanner.isSystemBundleID("group.com.acme.shared"))
        XCTAssertFalse(DefaultAppLeftoverScanner.isSystemBundleID("com.acme.App"))
    }

    func test_isCoveredByInstalled_matchesExactAndSubIDs() {
        let installed: Set<String> = ["com.acme.App"]
        XCTAssertTrue(DefaultAppLeftoverScanner.isCoveredByInstalled("com.acme.App", installed: installed))
        // A helper/XPC sub-ID of an installed app is covered.
        XCTAssertTrue(DefaultAppLeftoverScanner.isCoveredByInstalled("com.acme.App.Helper", installed: installed))
        // An unrelated ID is not.
        XCTAssertFalse(DefaultAppLeftoverScanner.isCoveredByInstalled("com.other.App", installed: installed))
        // A prefix that isn't a dot-boundary is not a sub-ID.
        XCTAssertFalse(DefaultAppLeftoverScanner.isCoveredByInstalled("com.acme.AppExtra", installed: installed))
    }

    func test_candidateBundleID_perRootKind() {
        XCTAssertEqual(
            DefaultAppLeftoverScanner.candidateBundleID(
                for: URL(fileURLWithPath: "/x/com.acme.App.plist"), kind: .preferences),
            "com.acme.App"
        )
        XCTAssertNil(
            DefaultAppLeftoverScanner.candidateBundleID(
                for: URL(fileURLWithPath: "/x/com.acme.App"), kind: .preferences),
            "A non-plist entry in Preferences yields no candidate"
        )
        XCTAssertEqual(
            DefaultAppLeftoverScanner.candidateBundleID(
                for: URL(fileURLWithPath: "/x/com.acme.App"), kind: .bundleNamedEntry),
            "com.acme.App"
        )
        XCTAssertEqual(
            DefaultAppLeftoverScanner.candidateBundleID(
                for: URL(fileURLWithPath: "/x/com.acme.App.savedState"), kind: .savedState),
            "com.acme.App"
        )
        XCTAssertNil(
            DefaultAppLeftoverScanner.candidateBundleID(
                for: URL(fileURLWithPath: "/x/com.acme.App"), kind: .savedState)
        )
    }

    // MARK: - Full scan

    func test_scan_flagsOrphansAndGroupsAcrossRoots() async throws {
        let appSupport = try makeDir("ApplicationSupport")
        let prefs = try makeDir("Preferences")

        // Orphan present in two roots → one group with both URLs.
        try FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("com.orphan.App", isDirectory: true),
            withIntermediateDirectories: true
        )
        try TestHelpers.createDummyFile(named: "com.orphan.App.plist", size: 100, in: prefs)
        // Installed app's support files → not flagged.
        try FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("com.installed.App", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Apple + human-named → never flagged.
        try TestHelpers.createDummyFile(named: "com.apple.finder.plist", size: 100, in: prefs)
        try FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("Google", isDirectory: true),
            withIntermediateDirectories: true
        )

        let scanner = DefaultAppLeftoverScanner(roots: [
            (appSupport, .bundleNamedEntry),
            (prefs, .preferences),
        ])

        let groups = await scanner.scan(installedBundleIDs: ["com.installed.App"])

        XCTAssertEqual(groups.map(\.bundleID), ["com.orphan.App"])
        XCTAssertEqual(groups.first?.displayName, "App")
        XCTAssertEqual(groups.first?.urls.count, 2,
                       "Both roots' entries for the orphan must group together")
    }

    func test_scan_doesNotFlagInstalledHelperSubID() async throws {
        let appSupport = try makeDir("ApplicationSupport")
        try FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("com.acme.App.Helper", isDirectory: true),
            withIntermediateDirectories: true
        )

        let scanner = DefaultAppLeftoverScanner(roots: [(appSupport, .bundleNamedEntry)])
        let groups = await scanner.scan(installedBundleIDs: ["com.acme.App"])

        XCTAssertTrue(groups.isEmpty,
                      "A helper sub-ID of an installed app must not be flagged")
    }

    func test_scan_sizesAndSortsLargestFirst() async throws {
        let caches = try makeDir("Caches")
        let small = caches.appendingPathComponent("com.small.App", isDirectory: true)
        let big = caches.appendingPathComponent("com.big.App", isDirectory: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "a.bin", size: 100, in: small)
        try TestHelpers.createDummyFile(named: "b.bin", size: 5_000, in: big)

        let scanner = DefaultAppLeftoverScanner(roots: [(caches, .bundleNamedEntry)])
        let groups = await scanner.scan(installedBundleIDs: [])

        XCTAssertEqual(groups.map(\.bundleID), ["com.big.App", "com.small.App"])
        XCTAssertEqual(groups.first?.totalBytes, 5_000)
        XCTAssertEqual(groups.last?.totalBytes, 100)
    }

    func test_scan_toleratesMissingRoot() async {
        let missing = tempRoot.appendingPathComponent("nope", isDirectory: true)
        let scanner = DefaultAppLeftoverScanner(roots: [(missing, .bundleNamedEntry)])
        let groups = await scanner.scan(installedBundleIDs: [])
        XCTAssertTrue(groups.isEmpty)
    }
}
