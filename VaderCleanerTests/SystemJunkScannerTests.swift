// SystemJunkScannerTests.swift
// Integration tests that drive SystemJunkScanner against temp directories via an injected SystemPathProviding stub, covering all eight junk categories plus exclusions and grouping.

import XCTest
@testable import VaderCleaner

/// Verifies `SystemJunkScanner` end-to-end. We never touch the real macOS
/// system paths — a `StubSystemPathProvider` returns roots under a temp
/// directory so each test is hermetic and deterministic, regardless of what's
/// in `/Library/Caches` on the test machine.
final class SystemJunkScannerTests: XCTestCase {

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

    // MARK: - Per-category coverage

    func test_scan_findsUserCacheFiles() async throws {
        let userCaches = try makeRoot("user-caches")
        try TestHelpers.createDummyFiles(count: 3, size: 16, in: userCaches)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: userCaches, category: .userCache)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.userCache]?.count, 3)
        XCTAssertEqual(result.totalSize, 48)
    }

    func test_scan_findsSystemCacheFiles() async throws {
        let systemCaches = try makeRoot("system-caches")
        try TestHelpers.createDummyFiles(count: 2, size: 64, in: systemCaches)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: systemCaches, category: .systemCache)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.systemCache]?.count, 2)
    }

    func test_scan_findsUserLogFiles() async throws {
        let userLogs = try makeRoot("user-logs")
        try TestHelpers.createDummyFile(named: "app.log", size: 256, in: userLogs)
        try TestHelpers.createDummyFile(named: "app.1.log", size: 256, in: userLogs)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: userLogs, category: .userLogs)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.userLogs]?.count, 2)
        XCTAssertEqual(result.sizeByCategory[.userLogs], 512)
    }

    func test_scan_findsSystemLogFiles() async throws {
        let systemLogs = try makeRoot("system-logs")
        try TestHelpers.createDummyFile(named: "kernel.log", size: 1_024, in: systemLogs)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: systemLogs, category: .systemLogs)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.systemLogs]?.count, 1)
        XCTAssertEqual(result.itemsByCategory[.systemLogs]?.first?.size, 1_024)
    }

    func test_scan_findsMailAttachments() async throws {
        let mail = try makeRoot("mail-downloads")
        try TestHelpers.createDummyFiles(count: 4, size: 8, in: mail)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: mail, category: .mailAttachments)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.mailAttachments]?.count, 4)
    }

    func test_scan_findsIOSBackups() async throws {
        let backups = try makeRoot("ios-backups")
        let backupSubdir = try TestHelpers.createNestedDirectories(depth: 2, in: backups)
        try TestHelpers.createDummyFile(named: "Manifest.plist", size: 200, in: backupSubdir)
        try TestHelpers.createDummyFile(named: "Info.plist", size: 100, in: backupSubdir)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: backups, category: .iosBackups)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.iosBackups]?.count, 2)
        XCTAssertEqual(result.sizeByCategory[.iosBackups], 300)
    }

    func test_scan_findsTrashOnHomeAndMountedVolumes() async throws {
        let homeTrash = try makeRoot("home-trash")
        let volumeTrash = try makeRoot("volume-trash")
        try TestHelpers.createDummyFiles(count: 1, size: 32, in: homeTrash)
        try TestHelpers.createDummyFiles(count: 2, size: 32, in: volumeTrash)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: homeTrash, category: .trash),
                ScanRoot(url: volumeTrash, category: .trash)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.trash]?.count, 3)
        XCTAssertEqual(result.sizeByCategory[.trash], 96)
    }

    func test_scan_findsLanguageFiles() async throws {
        let lprojRoot = try makeRoot("nl.lproj")
        try TestHelpers.createDummyFiles(count: 5, size: 4, in: lprojRoot)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: lprojRoot, category: .languageFiles)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.languageFiles]?.count, 5)
    }

    // MARK: - Exclusions

    /// Every file under the exclusion path must be omitted from the result,
    /// regardless of which category root it lived under. SystemJunkScanner
    /// forwards `excluding:` straight to `FileScanning`, so this is really an
    /// integration check that the wiring is in place — `FileScanner` itself
    /// owns the matching semantics (covered in `FileScannerTests`).
    func test_scan_respectsExclusions() async throws {
        let userCaches = try makeRoot("user-caches")
        let kept = userCaches.appendingPathComponent("kept", isDirectory: true)
        let excluded = userCaches.appendingPathComponent("excluded", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 2, size: 4, in: kept)
        try TestHelpers.createDummyFiles(count: 4, size: 4, in: excluded)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: userCaches, category: .userCache)
            ])
        )

        let result = try await scanner.scan(excluding: [excluded])

        XCTAssertEqual(result.itemsByCategory[.userCache]?.count, 2)
        for file in result.items {
            XCTAssertFalse(
                file.url.path.hasPrefix(excluded.path),
                "Excluded path leaked: \(file.url.path)"
            )
        }
    }

    // MARK: - Aggregation

    /// `ScanResult.itemsByCategory` must group files by the category they were
    /// tagged with — no cross-contamination, no missing buckets, and absent
    /// categories must not appear (rather than mapping to an empty array).
    func test_scan_resultGroupsByCategory() async throws {
        let userCaches = try makeRoot("user-caches")
        let systemLogs = try makeRoot("system-logs")
        let trash = try makeRoot("trash")
        try TestHelpers.createDummyFiles(count: 2, size: 4, in: userCaches)
        try TestHelpers.createDummyFiles(count: 3, size: 4, in: systemLogs)
        try TestHelpers.createDummyFiles(count: 1, size: 4, in: trash)
        let scanner = SystemJunkScanner(
            pathProvider: StubSystemPathProvider(roots: [
                ScanRoot(url: userCaches, category: .userCache),
                ScanRoot(url: systemLogs, category: .systemLogs),
                ScanRoot(url: trash, category: .trash)
            ])
        )

        let result = try await scanner.scan(excluding: [])

        XCTAssertEqual(result.itemsByCategory[.userCache]?.count, 2)
        XCTAssertEqual(result.itemsByCategory[.systemLogs]?.count, 3)
        XCTAssertEqual(result.itemsByCategory[.trash]?.count, 1)
        XCTAssertNil(
            result.itemsByCategory[.iosBackups],
            "Empty categories must not appear in the dictionary"
        )
        XCTAssertNil(
            result.itemsByCategory[.mailAttachments],
            "Empty categories must not appear in the dictionary"
        )
    }

    // MARK: - Helpers

    /// Creates a uniquely named subdirectory under `tempRoot` so each scan
    /// root in a test has its own isolated tree.
    private func makeRoot(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Stub

/// Returns a fixed list of `ScanRoot` values supplied at construction time,
/// bypassing any real filesystem layout. Lets tests drive `SystemJunkScanner`
/// over temp directories deterministically.
private struct StubSystemPathProvider: SystemPathProviding {
    private let stubbedRoots: [ScanRoot]
    init(roots: [ScanRoot]) { self.stubbedRoots = roots }
    func roots() -> [ScanRoot] { stubbedRoots }
}
