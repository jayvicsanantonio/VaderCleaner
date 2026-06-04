// InstallationFileScannerTests.swift
// Drives DefaultInstallationFileScanner against temp fixture roots, covering extension filtering, multi-root aggregation, size-descending order, the regular-file guard, and missing-root tolerance — all hermetic, never touching the real Downloads/Desktop.

import XCTest
@testable import VaderCleaner

final class InstallationFileScannerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()
    }

    override func tearDown() {
        if let tempRoot {
            TestHelpers.tearDownTempDirectory(tempRoot)
        }
        tempRoot = nil
        super.tearDown()
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Extension filtering

    func test_scan_keepsOnlyInstallerExtensions() async throws {
        let root = try makeRoot("downloads")
        try TestHelpers.createDummyFile(named: "Installer.dmg", size: 100, in: root)
        try TestHelpers.createDummyFile(named: "App.pkg", size: 100, in: root)
        try TestHelpers.createDummyFile(named: "Ubuntu.iso", size: 100, in: root)
        try TestHelpers.createDummyFile(named: "notes.txt", size: 100, in: root)
        try TestHelpers.createDummyFile(named: "photo.png", size: 100, in: root)

        let scanner = DefaultInstallationFileScanner(roots: [root])
        let files = await scanner.scan()

        XCTAssertEqual(
            Set(files.map(\.name)),
            ["Installer.dmg", "App.pkg", "Ubuntu.iso"],
            "Only .dmg / .pkg / .iso files must be surfaced"
        )
    }

    func test_scan_classifiesKinds() async throws {
        let root = try makeRoot("downloads")
        try TestHelpers.createDummyFile(named: "Installer.dmg", size: 10, in: root)
        try TestHelpers.createDummyFile(named: "Ubuntu.iso", size: 10, in: root)
        try TestHelpers.createDummyFile(named: "App.pkg", size: 10, in: root)

        let scanner = DefaultInstallationFileScanner(roots: [root])
        let files = await scanner.scan()
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.kind) })

        XCTAssertEqual(byName["Installer.dmg"], .diskImage)
        XCTAssertEqual(byName["Ubuntu.iso"], .diskImage)
        XCTAssertEqual(byName["App.pkg"], .package)
    }

    func test_scan_isCaseInsensitiveOnExtension() async throws {
        let root = try makeRoot("downloads")
        try TestHelpers.createDummyFile(named: "Installer.DMG", size: 10, in: root)

        let scanner = DefaultInstallationFileScanner(roots: [root])
        let files = await scanner.scan()

        XCTAssertEqual(files.map(\.name), ["Installer.DMG"])
    }

    // MARK: - Multi-root + ordering

    func test_scan_aggregatesAcrossRootsAndSortsBySizeDescending() async throws {
        let downloads = try makeRoot("downloads")
        let desktop = try makeRoot("desktop")
        try TestHelpers.createDummyFile(named: "small.dmg", size: 100, in: downloads)
        try TestHelpers.createDummyFile(named: "big.pkg", size: 5_000, in: desktop)
        try TestHelpers.createDummyFile(named: "medium.iso", size: 1_000, in: downloads)

        let scanner = DefaultInstallationFileScanner(roots: [downloads, desktop])
        let files = await scanner.scan()

        XCTAssertEqual(
            files.map(\.name),
            ["big.pkg", "medium.iso", "small.dmg"],
            "Files from both roots must be merged and ordered largest-first"
        )
        XCTAssertEqual(files.first?.sizeBytes, 5_000)
    }

    // MARK: - Guards

    func test_scan_ignoresDirectoriesNamedLikeInstallers() async throws {
        let root = try makeRoot("downloads")
        // A folder a user happened to name "Project.dmg" must never be offered
        // for removal as an installer.
        let folder = root.appendingPathComponent("Project.dmg", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "real.dmg", size: 10, in: root)

        let scanner = DefaultInstallationFileScanner(roots: [root])
        let files = await scanner.scan()

        XCTAssertEqual(files.map(\.name), ["real.dmg"],
                       "Directories must be skipped even when named like an installer")
    }

    func test_scan_isShallow_doesNotRecurseIntoSubfolders() async throws {
        let root = try makeRoot("downloads")
        let nested = root.appendingPathComponent("Old Installers", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "nested.dmg", size: 10, in: nested)
        try TestHelpers.createDummyFile(named: "top.dmg", size: 10, in: root)

        let scanner = DefaultInstallationFileScanner(roots: [root])
        let files = await scanner.scan()

        XCTAssertEqual(files.map(\.name), ["top.dmg"],
                       "The scan must stay one level deep and not descend into subfolders")
    }

    func test_scan_toleratesMissingRoot() async throws {
        let present = try makeRoot("downloads")
        try TestHelpers.createDummyFile(named: "Installer.dmg", size: 10, in: present)
        let missing = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)

        let scanner = DefaultInstallationFileScanner(roots: [present, missing])
        let files = await scanner.scan()

        XCTAssertEqual(files.map(\.name), ["Installer.dmg"],
                       "A missing root must not sink the rest of the scan")
    }

    func test_scan_emptyRoots_returnsEmpty() async throws {
        let root = try makeRoot("downloads")
        let scanner = DefaultInstallationFileScanner(roots: [root])
        let files = await scanner.scan()
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - Default roots

    func test_defaultRoots_areDownloadsAndDesktop() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let roots = DefaultInstallationFileScanner.defaultRoots(homeDirectory: home)
        XCTAssertEqual(roots.map(\.lastPathComponent), ["Downloads", "Desktop"])
    }
}
