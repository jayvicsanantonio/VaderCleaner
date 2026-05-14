// AppDiscoveryTests.swift
// Verifies that DefaultAppDiscovery surfaces installed .app bundles, parses Info.plist metadata, filters Apple system apps, and tolerates malformed bundles.

import XCTest
@testable import VaderCleaner

final class AppDiscoveryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            TestHelpers.tearDownTempDirectory(tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Discovery basics

    /// A bundle laid out under the fixture root must surface in
    /// `installedApps(includingSystemApps:)` with parsed metadata.
    func test_installedApps_returnsBundlesUnderRoot() async throws {
        try makeAppBundle(named: "Helio", bundleID: "com.acme.helio", version: "1.2.3")

        let discovery = DefaultAppDiscovery(
            homeDirectory: tempRoot.appendingPathComponent("home", isDirectory: true),
            additionalRoots: [tempRoot],
            useDefaultRoots: false
        )

        let apps = try await discovery.installedApps(includingSystemApps: true)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.name, "Helio")
        XCTAssertEqual(apps.first?.bundleID, "com.acme.helio")
        XCTAssertEqual(apps.first?.version, "1.2.3")
        XCTAssertEqual(apps.first?.bundleURL.lastPathComponent, "Helio.app")
    }

    /// Multiple apps must come back sorted by case-insensitive name so
    /// the rendered list is deterministic and human-friendly.
    func test_installedApps_sortsResultsAlphabetically() async throws {
        try makeAppBundle(named: "Zeppelin", bundleID: "com.acme.zeppelin")
        try makeAppBundle(named: "Aria", bundleID: "com.acme.aria")
        try makeAppBundle(named: "mango", bundleID: "com.acme.mango")

        let discovery = DefaultAppDiscovery(
            homeDirectory: tempRoot.appendingPathComponent("home", isDirectory: true),
            additionalRoots: [tempRoot],
            useDefaultRoots: false
        )
        let apps = try await discovery.installedApps(includingSystemApps: true)
        XCTAssertEqual(apps.map(\.name), ["Aria", "mango", "Zeppelin"])
    }

    /// `com.apple.*` bundles must be filtered out unless the toggle is on.
    func test_installedApps_excludesAppleBundlesByDefault() async throws {
        try makeAppBundle(named: "Finder", bundleID: "com.apple.finder")
        try makeAppBundle(named: "ThirdParty", bundleID: "com.acme.thirdparty")

        let discovery = DefaultAppDiscovery(
            homeDirectory: tempRoot.appendingPathComponent("home", isDirectory: true),
            additionalRoots: [tempRoot],
            useDefaultRoots: false
        )

        let withoutSystem = try await discovery.installedApps(includingSystemApps: false)
        XCTAssertEqual(withoutSystem.map(\.bundleID), ["com.acme.thirdparty"])

        let withSystem = try await discovery.installedApps(includingSystemApps: true)
        XCTAssertEqual(withSystem.map(\.bundleID).sorted(),
                       ["com.acme.thirdparty", "com.apple.finder"])
    }

    /// Bundles without a parseable `Info.plist` must be skipped without
    /// derailing discovery for the remaining apps.
    func test_installedApps_skipsBundlesWithoutInfoPlist() async throws {
        try makeAppBundle(named: "Good", bundleID: "com.acme.good")
        // Make a malformed bundle with no Info.plist at all.
        let badBundle = tempRoot.appendingPathComponent("Bad.app", isDirectory: true)
        try FileManager.default.createDirectory(at: badBundle, withIntermediateDirectories: true)

        let discovery = DefaultAppDiscovery(
            homeDirectory: tempRoot.appendingPathComponent("home", isDirectory: true),
            additionalRoots: [tempRoot],
            useDefaultRoots: false
        )
        let apps = try await discovery.installedApps(includingSystemApps: true)
        XCTAssertEqual(apps.map(\.bundleID), ["com.acme.good"])
    }

    /// `useDefaultRoots: true` must include `/System/Applications` and
    /// its `Utilities` subfolder. Many Apple system apps live there on
    /// modern macOS; without these roots the "Show system apps" toggle
    /// would silently fail to surface most system apps even after the
    /// `com.apple.*` filter is disabled. Codex P2 on PR #58.
    func test_init_defaultRootsIncludeSystemApplications() {
        let discovery = DefaultAppDiscovery(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            useDefaultRoots: true
        )
        let mirror = Mirror(reflecting: discovery)
        let roots = mirror.children.first(where: { $0.label == "roots" })?.value as? [URL] ?? []
        let rootPaths = roots.map(\.path)
        XCTAssertTrue(rootPaths.contains("/Applications"))
        XCTAssertTrue(rootPaths.contains("/Applications/Utilities"))
        XCTAssertTrue(rootPaths.contains("/Users/test/Applications"))
        XCTAssertTrue(rootPaths.contains("/System/Applications"))
        XCTAssertTrue(rootPaths.contains("/System/Applications/Utilities"))
    }

    /// `_MASReceipt/receipt` presence flips `isAppStore` to `true`.
    func test_installedApps_detectsAppStoreInstall() async throws {
        try makeAppBundle(named: "Premium", bundleID: "com.acme.premium", appStore: true)
        try makeAppBundle(named: "Sideloaded", bundleID: "com.acme.sideloaded", appStore: false)

        let discovery = DefaultAppDiscovery(
            homeDirectory: tempRoot.appendingPathComponent("home", isDirectory: true),
            additionalRoots: [tempRoot],
            useDefaultRoots: false
        )
        let apps = try await discovery.installedApps(includingSystemApps: true)
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })
        XCTAssertTrue(byID["com.acme.premium"]?.isAppStore == true)
        XCTAssertTrue(byID["com.acme.sideloaded"]?.isAppStore == false)
    }

    /// Bundle size is computed on demand by `bundleSize(at:)`, not
    /// during the initial discovery pass — folding the directory walk
    /// into `installedApps` would pin launch on multi-second I/O for
    /// users with many installed apps.
    func test_bundleSize_sumsRegularFiles() async throws {
        let bundle = try makeAppBundle(named: "Sized", bundleID: "com.acme.sized")
        let executableDir = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 2, size: 4_096, in: executableDir)

        let discovery = DefaultAppDiscovery(
            homeDirectory: tempRoot.appendingPathComponent("home", isDirectory: true),
            additionalRoots: [tempRoot],
            useDefaultRoots: false
        )
        let size = await discovery.bundleSize(at: bundle)
        // Two files × 4096 bytes + the Info.plist contributes its own size.
        XCTAssertGreaterThanOrEqual(size, 8_192)
    }

    // MARK: - Fixture helpers

    @discardableResult
    private func makeAppBundle(
        named name: String,
        bundleID: String,
        version: String? = "1.0",
        appStore: Bool = false
    ) throws -> URL {
        let bundle = tempRoot.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name
        ]
        if let version {
            plist["CFBundleShortVersionString"] = version
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        if appStore {
            let receiptDir = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
            try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
            try Data([0x00, 0x01]).write(to: receiptDir.appendingPathComponent("receipt"))
        }
        return bundle
    }
}
