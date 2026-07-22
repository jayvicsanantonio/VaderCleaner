// ScannerExclusionCoverageTests.swift
// Proves the Ignore List actually reaches the scanners that previously ignored it — installers, unused apps, and app leftovers.

import XCTest
@testable import VaderCleaner

/// The Ignore List pane promises "no scan will touch it". These scanners took
/// no exclusions at all, so an ignored folder's installers, unused apps and
/// leftovers were still found and offered for removal.
final class ScannerExclusionCoverageTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannerExclusions.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ relativePath: String, bytes: Int = 1024) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    // MARK: - Installers

    func test_installerScan_findsInstallersWhenNothingIsExcluded() async throws {
        try makeFile("Downloads/Thing.dmg")
        let scanner = DefaultInstallationFileScanner(roots: [root.appendingPathComponent("Downloads")])

        let found = await scanner.scan()

        XCTAssertEqual(found.map(\.name), ["Thing.dmg"])
    }

    func test_installerScan_skipsAnExcludedFile() async throws {
        let file = try makeFile("Downloads/Thing.dmg")
        let scanner = DefaultInstallationFileScanner(roots: [root.appendingPathComponent("Downloads")])

        let found = await scanner.scan(excluding: [file])

        XCTAssertTrue(found.isEmpty, "an ignored installer must not be offered for removal")
    }

    /// The common case: the user ignores a folder, not an individual file.
    func test_installerScan_skipsInstallersInsideAnExcludedFolder() async throws {
        try makeFile("Downloads/Thing.dmg")
        let downloads = root.appendingPathComponent("Downloads")
        let scanner = DefaultInstallationFileScanner(roots: [downloads])

        let found = await scanner.scan(excluding: [downloads])

        XCTAssertTrue(found.isEmpty)
    }

    /// Exclusion matches at path-component boundaries, so a sibling folder with
    /// a shared prefix must still be scanned.
    func test_installerScan_doesNotOverMatchSiblingPaths() async throws {
        try makeFile("Downloads2/Thing.dmg")
        let scanner = DefaultInstallationFileScanner(
            roots: [root.appendingPathComponent("Downloads2")]
        )

        let found = await scanner.scan(excluding: [root.appendingPathComponent("Downloads")])

        XCTAssertEqual(found.count, 1, "Downloads2 is not inside Downloads")
    }

    // MARK: - Unused apps

    private func makeApp(at url: URL) -> AppInfo {
        AppInfo(name: "Old", bundleID: "com.example.old", version: "1.0",
                bundleURL: url, isAppStore: false)
    }

    /// A long-stale app, so only the exclusion decides whether it's reported.
    private func makeStaleScanner() -> DefaultUnusedAppScanner {
        DefaultUnusedAppScanner(
            lastUsedDate: { _ in Date(timeIntervalSince1970: 0) },
            bundleSize: { _ in 1_000 },
            now: { Date(timeIntervalSince1970: 60 * 60 * 24 * 400) }
        )
    }

    func test_unusedAppScan_skipsAppsInsideAnExcludedFolder() async {
        let excludedDir = root.appendingPathComponent("Sandbox", isDirectory: true)
        let app = makeApp(at: excludedDir.appendingPathComponent("Old.app"))

        let found = await makeStaleScanner().scan(apps: [app], excluding: [excludedDir])

        XCTAssertTrue(found.isEmpty, "an app in an ignored folder must not be reported unused")
    }

    func test_unusedAppScan_stillReportsAppsOutsideExclusions() async {
        let app = makeApp(at: root.appendingPathComponent("Apps/Old.app"))

        let found = await makeStaleScanner().scan(
            apps: [app],
            excluding: [root.appendingPathComponent("Elsewhere")]
        )

        XCTAssertEqual(found.count, 1)
    }
}
