// AssociatedFileFinderTests.swift
// Verifies that DefaultAssociatedFileFinder locates preferences, caches, logs, containers, group containers, saved state, and launch agents that belong to a given bundle ID.

import XCTest
@testable import VaderCleaner

final class AssociatedFileFinderTests: XCTestCase {

    private var tempRoot: URL!
    private var home: URL!
    private var systemLibrary: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()
        home = tempRoot.appendingPathComponent("home", isDirectory: true)
        systemLibrary = tempRoot.appendingPathComponent("system_library", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemLibrary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            TestHelpers.tearDownTempDirectory(tempRoot)
        }
        tempRoot = nil
        home = nil
        systemLibrary = nil
        try super.tearDownWithError()
    }

    // MARK: - Preferences

    func test_find_returnsPreferencesPlistByExactName() async throws {
        try makeFile(under: "Library/Preferences/com.acme.helio.plist", size: 128)
        try makeFile(under: "Library/Preferences/com.unrelated.plist", size: 64)

        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.category, .preferences)
        XCTAssertEqual(result.first?.sizeBytes, 128)
        XCTAssertEqual(result.first?.url.lastPathComponent, "com.acme.helio.plist")
    }

    /// A Preferences scan must reject non-`.plist` entries that happen
    /// to share the bundle-ID prefix — without the extension filter, a
    /// stray `com.acme.helio.db` would be Trashed during uninstall.
    func test_find_excludesNonPlistEntriesUnderPreferences() async throws {
        try makeFile(under: "Library/Preferences/com.acme.helio.plist", size: 16)
        try makeFile(under: "Library/Preferences/com.acme.helio.db", size: 64)
        try makeFile(under: "Library/Preferences/com.acme.helio.lock", size: 8)

        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        let names = result.map { $0.url.lastPathComponent }
        XCTAssertTrue(names.contains("com.acme.helio.plist"))
        XCTAssertFalse(names.contains("com.acme.helio.db"),
                       "Preferences scan must require the .plist suffix")
        XCTAssertFalse(names.contains("com.acme.helio.lock"),
                       "Preferences scan must require the .plist suffix")
    }

    /// A Group Containers / LaunchAgents scan must reject siblings that
    /// share the bundle-ID prefix but lack a dot boundary on the
    /// matched substring (`com.acme.helio2`, `com.acme.helioworld`).
    /// The finder emits the matched directory itself (Group Containers
    /// are directories the user wants Trashed wholesale), so the
    /// assertions match on the last path component.
    func test_find_groupContainersAndLaunchAgentsRejectNonBoundaryMatches() async throws {
        // Wanted hits.
        try makeFile(under: "Library/Group Containers/TEAM1234.com.acme.helio/shared.bin", size: 1)
        try makeFile(under: "Library/LaunchAgents/com.acme.helio.helper.plist", size: 1)
        // Sibling apps — must be excluded.
        try makeFile(under: "Library/Group Containers/TEAM5678.com.acme.helio2/shared.bin", size: 1)
        try makeFile(under: "Library/LaunchAgents/com.acme.helio2.helper.plist", size: 1)
        try makeFile(under: "Library/LaunchAgents/com.acme.helioworld.plist", size: 1)

        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        let names = result.map { $0.url.lastPathComponent }
        XCTAssertTrue(names.contains("TEAM1234.com.acme.helio"))
        XCTAssertTrue(names.contains("com.acme.helio.helper.plist"))
        XCTAssertFalse(names.contains("TEAM5678.com.acme.helio2"),
                       "Substring match must not pull in helio2 sibling app")
        XCTAssertFalse(names.contains("com.acme.helio2.helper.plist"),
                       "Substring match must not pull in helio2 sibling app")
        XCTAssertFalse(names.contains("com.acme.helioworld.plist"),
                       "Substring match must require a dot boundary")
    }

    /// A search for `com.acme.helio` must NOT also match
    /// `com.acme.helio2.plist` or `com.acme.helioworld.savedState` —
    /// the bundle ID has to be followed by a dot (or end-of-name).
    func test_find_doesNotMatchBundleIDPrefixOnOtherBundles() async throws {
        try makeFile(under: "Library/Preferences/com.acme.helio.plist", size: 16)
        try makeFile(under: "Library/Preferences/com.acme.helio2.plist", size: 32)
        try makeFile(under: "Library/Saved Application State/com.acme.helioworld.savedState/keep", size: 64)

        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        let names = result.map { $0.url.lastPathComponent }
        XCTAssertTrue(names.contains("com.acme.helio.plist"))
        XCTAssertFalse(names.contains("com.acme.helio2.plist"),
                       "Prefix match must not pull in sibling bundles")
        XCTAssertFalse(names.contains("com.acme.helioworld.savedState"),
                       "Prefix match must require a dot separator")
    }

    func test_find_returnsByHostPreferences() async throws {
        try makeFile(under: "Library/Preferences/ByHost/com.acme.helio.ABCDEF.plist", size: 32)
        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")

        XCTAssertTrue(result.contains(where: { $0.url.lastPathComponent.contains("com.acme.helio") }))
        XCTAssertTrue(result.allSatisfy { $0.category == .preferences })
    }

    // MARK: - Standard ~/Library locations

    func test_find_includesApplicationSupportAndCachesAndLogsAndContainers() async throws {
        try makeFile(under: "Library/Application Support/com.acme.helio/notes.dat", size: 1_000)
        try makeFile(under: "Library/Caches/com.acme.helio/blob.bin", size: 2_000)
        try makeFile(under: "Library/Logs/com.acme.helio/app.log", size: 500)
        try makeFile(under: "Library/Containers/com.acme.helio/Data/keep.txt", size: 250)

        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        let byCategory = Dictionary(grouping: result, by: \.category)

        XCTAssertEqual(byCategory[.applicationSupport]?.count, 1)
        XCTAssertEqual(byCategory[.applicationSupport]?.first?.sizeBytes, 1_000)
        XCTAssertEqual(byCategory[.cache]?.count, 1)
        XCTAssertEqual(byCategory[.cache]?.first?.sizeBytes, 2_000)
        XCTAssertEqual(byCategory[.logs]?.count, 1)
        XCTAssertEqual(byCategory[.logs]?.first?.sizeBytes, 500)
        XCTAssertEqual(byCategory[.containers]?.count, 1)
        XCTAssertEqual(byCategory[.containers]?.first?.sizeBytes, 250)
    }

    /// Vendors prefix Group Containers with their Team ID, so substring
    /// matching is required.
    func test_find_includesGroupContainersWithTeamIDPrefix() async throws {
        try makeFile(under: "Library/Group Containers/TEAM1234.com.acme.helio/shared.bin", size: 999)
        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        XCTAssertEqual(result.filter { $0.category == .groupContainers }.count, 1)
        XCTAssertEqual(result.first(where: { $0.category == .groupContainers })?.sizeBytes, 999)
    }

    func test_find_includesSavedApplicationState() async throws {
        try makeFile(under: "Library/Saved Application State/com.acme.helio.savedState/keep", size: 12)
        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        let savedState = result.first(where: { $0.category == .savedState })
        XCTAssertNotNil(savedState)
        XCTAssertEqual(savedState?.sizeBytes, 12)
    }

    /// LaunchAgents lookup must require the `.plist` extension —
    /// vendors occasionally drop unrelated companion files (binaries,
    /// scripts, sockets) into LaunchAgents directories and a too-broad
    /// substring match would Trash them during uninstall.
    func test_find_launchAgentsRequireDotPlistSuffix() async throws {
        try makeFile(under: "Library/LaunchAgents/com.acme.helio.updater.plist", size: 16)
        try makeFile(under: "Library/LaunchAgents/com.acme.helio.helper.binary", size: 8_192)
        try makeFile(under: "Library/LaunchAgents/com.acme.helio.socket", size: 0)

        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        let names = result.filter { $0.category == .launchAgents }.map { $0.url.lastPathComponent }
        XCTAssertEqual(names, ["com.acme.helio.updater.plist"])
    }

    func test_find_includesUserAndSystemLaunchAgents() async throws {
        try makeFile(under: "Library/LaunchAgents/com.acme.helio.updater.plist", size: 64)
        let systemAgentURL = systemLibrary
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.acme.helio.helper.plist")
        try FileManager.default.createDirectory(
            at: systemAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: 80).write(to: systemAgentURL)

        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        let launchAgents = result.filter { $0.category == .launchAgents }
        XCTAssertEqual(launchAgents.count, 2)
        XCTAssertEqual(launchAgents.reduce(0) { $0 + $1.sizeBytes }, 144)
    }

    // MARK: - Empty / missing

    /// A bundle ID with nothing on disk returns an empty array.
    func test_find_returnsEmptyArrayForUnknownBundleID() async {
        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.unknown.ghost")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Ordering

    /// Results are stably ordered by category in declaration order, then
    /// by URL path — so SwiftUI list diffing is predictable.
    func test_find_resultsAreStableOrderedByCategoryThenPath() async throws {
        try makeFile(under: "Library/Logs/com.acme.helio/app.log", size: 1)
        try makeFile(under: "Library/Preferences/com.acme.helio.plist", size: 1)
        try makeFile(under: "Library/Caches/com.acme.helio/blob.bin", size: 1)

        let finder = makeFinder()
        let result = await finder.find(forBundleID: "com.acme.helio")
        let categories = result.map(\.category)
        let categoryRanks = categories.map { AssociatedFileCategory.allCases.firstIndex(of: $0)! }
        XCTAssertEqual(categoryRanks, categoryRanks.sorted())
    }

    // MARK: - Helpers

    private func makeFinder() -> DefaultAssociatedFileFinder {
        DefaultAssociatedFileFinder(
            fileManager: .default,
            homeDirectory: home,
            systemLibraryDirectory: systemLibrary
        )
    }

    @discardableResult
    private func makeFile(under relativePath: String, size: Int) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xCD, count: size).write(to: url)
        return url
    }
}
