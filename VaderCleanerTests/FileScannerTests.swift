// FileScannerTests.swift
// Integration tests that drive FileScanner over real temporary directories to verify recursion, exclusions, sizes, symlinks, and error handling.

import XCTest
@testable import VaderCleaner

/// Exercises `FileScanner` against real temp directories created via
/// `TestHelpers`. We deliberately avoid mocking `FileManager` — the whole
/// point of this layer is to integrate with the file system, and a mock
/// would just re-encode our own assumptions about it.
final class FileScannerTests: XCTestCase {

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

    // MARK: - Recursion

    func test_scan_enumeratesFilesRecursively() async throws {
        let nested = try TestHelpers.createNestedDirectories(depth: 3, in: tempRoot)
        try TestHelpers.createDummyFiles(count: 2, size: 16, in: tempRoot)
        try TestHelpers.createDummyFiles(count: 3, size: 32, in: nested)

        let scanner = FileScanner()
        let files = try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .userCache)],
            excluding: []
        )

        XCTAssertEqual(files.count, 5)
    }

    func test_scan_emptyDirectoryReturnsEmpty() async throws {
        let scanner = FileScanner()
        let files = try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .userCache)],
            excluding: []
        )

        XCTAssertEqual(files, [])
    }

    func test_scan_assignsCategoryFromMatchingRoot() async throws {
        let cacheRoot = tempRoot.appendingPathComponent("cache", isDirectory: true)
        let trashRoot = tempRoot.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 2, size: 8, in: cacheRoot)
        try TestHelpers.createDummyFiles(count: 1, size: 8, in: trashRoot)

        let scanner = FileScanner()
        let files = try await scanner.scan(
            roots: [
                ScanRoot(url: cacheRoot, category: .userCache),
                ScanRoot(url: trashRoot, category: .trash)
            ],
            excluding: []
        )

        XCTAssertEqual(files.filter { $0.category == .userCache }.count, 2)
        XCTAssertEqual(files.filter { $0.category == .trash }.count, 1)
    }

    func test_scan_emitsMultipleBatchesBeforeCompleting() async throws {
        try TestHelpers.createDummyFiles(count: 5, size: 8, in: tempRoot)

        let scanner = FileScanner()
        var batchSizes: [Int] = []
        try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .userCache)],
            excluding: [],
            batchSize: 2
        ) { batch in
            batchSizes.append(batch.count)
        }

        XCTAssertEqual(batchSizes, [2, 2, 1])
    }

    func test_scan_stopsWhenBatchConsumerCancels() async throws {
        try TestHelpers.createDummyFiles(count: 20, size: 8, in: tempRoot)

        let scanner = FileScanner()
        var deliveredCount = 0

        do {
            try await scanner.scan(
                roots: [ScanRoot(url: tempRoot, category: .userCache)],
                excluding: [],
                batchSize: 1
            ) { batch in
                deliveredCount += batch.count
                if deliveredCount == 3 {
                    throw CancellationError()
                }
            }
            XCTFail("Expected cancellation to stop the scan")
        } catch is CancellationError {
            XCTAssertEqual(deliveredCount, 3)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func test_scan_doesNotDeliverBufferedBatchAfterTaskCancellation() async throws {
        try TestHelpers.createDummyFile(named: "pending.bin", size: 8, in: tempRoot)

        let scanner = FileScanner()
        var didDeliverBatch = false
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            try await scanner.scan(
                roots: [ScanRoot(url: tempRoot, category: .userCache)],
                excluding: [],
                batchSize: 10
            ) { _ in
                didDeliverBatch = true
            }
        }

        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation to stop the scan")
        } catch is CancellationError {
            XCTAssertFalse(didDeliverBatch)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - Exclusions

    func test_scan_skipsFilesUnderExcludedPath() async throws {
        let kept = tempRoot.appendingPathComponent("kept", isDirectory: true)
        let excluded = tempRoot.appendingPathComponent("excluded", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 2, size: 4, in: kept)
        try TestHelpers.createDummyFiles(count: 5, size: 4, in: excluded)

        let scanner = FileScanner()
        let files = try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .userCache)],
            excluding: [excluded]
        )

        XCTAssertEqual(files.count, 2)
        for file in files {
            XCTAssertFalse(
                file.url.path.hasPrefix(excluded.path),
                "Excluded path leaked: \(file.url.path)"
            )
        }
    }

    /// Exclusion match must be at path-component boundaries, not raw prefix —
    /// otherwise excluding `/tmp/foo` would also exclude `/tmp/foobar`.
    func test_scan_exclusionMatchesAtPathBoundary() async throws {
        let foo = tempRoot.appendingPathComponent("foo", isDirectory: true)
        let foobar = tempRoot.appendingPathComponent("foobar", isDirectory: true)
        try FileManager.default.createDirectory(at: foo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foobar, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 1, size: 4, in: foo)
        try TestHelpers.createDummyFiles(count: 1, size: 4, in: foobar)

        let scanner = FileScanner()
        let files = try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .userCache)],
            excluding: [foo]
        )

        XCTAssertEqual(files.count, 1, "Only the foobar file should remain")
        XCTAssertTrue(files[0].url.path.contains("foobar"))
    }

    // MARK: - Total size

    func test_scan_resultTotalSizeMatchesFileSizes() async throws {
        try TestHelpers.createDummyFile(named: "a.bin", size: 100, in: tempRoot)
        try TestHelpers.createDummyFile(named: "b.bin", size: 250, in: tempRoot)
        try TestHelpers.createDummyFile(named: "c.bin", size: 50, in: tempRoot)

        let scanner = FileScanner()
        let files = try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .userCache)],
            excluding: []
        )
        let result = ScanResult(items: files)

        XCTAssertEqual(result.totalSize, 400)
    }

    // MARK: - Symlinks

    /// A symlink inside the scanned tree pointing to a file *outside* it must
    /// not pull the external file into the result. Our enumerator skips
    /// symlinks outright; this test pins that contract regardless of the
    /// underlying mechanism (so a future switch to "follow symlinks under
    /// root only" would still need this assertion to hold).
    func test_scan_skipsSymlinkPointingOutsideScannedDirectory() async throws {
        let outside = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(outside) }
        let externalFile = try TestHelpers.createDummyFile(
            named: "external.bin",
            size: 1_000,
            in: outside
        )
        try TestHelpers.createDummyFile(named: "inside.bin", size: 8, in: tempRoot)
        let symlink = tempRoot.appendingPathComponent("link-to-outside")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: externalFile
        )

        let scanner = FileScanner()
        let files = try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .userCache)],
            excluding: []
        )

        let externalCanonical = externalFile.resolvingSymlinksInPath().path
        for file in files {
            XCTAssertNotEqual(
                file.url.resolvingSymlinksInPath().path,
                externalCanonical,
                "Scanner followed a symlink outside the scanned root"
            )
        }
        let totalSize = ScanResult(items: files).totalSize
        XCTAssertLessThan(
            totalSize,
            1_000,
            "External 1 KB file appears to have been counted via symlink"
        )
    }

    // MARK: - Packages

    func test_fileManagerSkipsPackageDescendantsEmitsPackageURLItself() throws {
        let package = tempRoot.appendingPathComponent("Demo.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let innerFile = try TestHelpers.createDummyFile(named: "Info.plist", size: 16, in: contents)

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: tempRoot,
            includingPropertiesForKeys: [.isPackageKey],
            options: [.skipsPackageDescendants]
        ))
        let urls = enumerator.compactMap { $0 as? URL }
        let resolvedPaths = Set(urls.map { $0.resolvingSymlinksInPath().path })

        XCTAssertTrue(
            resolvedPaths.contains(package.resolvingSymlinksInPath().path),
            ".skipsPackageDescendants should still surface the package URL so package-as-file mode can emit it"
        )
        XCTAssertFalse(
            resolvedPaths.contains(innerFile.resolvingSymlinksInPath().path),
            ".skipsPackageDescendants should skip package internals"
        )
    }

    func test_scan_packagesAsFilesEmitsPackageDirectoryAsSingleRolledUpItem() async throws {
        let package = tempRoot.appendingPathComponent("Demo.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "a.bin", size: 32, in: contents)
        try TestHelpers.createDummyFile(named: "b.bin", size: 64, in: contents)

        let scanner = FileScanner()
        var files: [ScannedFile] = []
        try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .largeFile)],
            excluding: [],
            options: FileScanOptions(packagesAsFiles: true),
            batchSize: FileScanner.defaultBatchSize
        ) { batch in
            files.append(contentsOf: batch)
        }

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.url.resolvingSymlinksInPath().path, package.resolvingSymlinksInPath().path)
        XCTAssertEqual(files.first?.size, 96)
        XCTAssertEqual(files.first?.category, .largeFile)
    }

    func test_scan_packagesAsFilesDescendsWhenExclusionTargetsPackageChild() async throws {
        let package = tempRoot.appendingPathComponent("Demo.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let kept = try TestHelpers.createDummyFile(named: "kept.bin", size: 32, in: contents)
        let excluded = try TestHelpers.createDummyFile(named: "excluded.bin", size: 64, in: contents)

        let scanner = FileScanner()
        var files: [ScannedFile] = []
        try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .largeFile)],
            excluding: [excluded],
            options: FileScanOptions(packagesAsFiles: true),
            batchSize: FileScanner.defaultBatchSize
        ) { batch in
            files.append(contentsOf: batch)
        }

        XCTAssertEqual(
            files.map { $0.url.resolvingSymlinksInPath().path },
            [kept.resolvingSymlinksInPath().path]
        )
        XCTAssertEqual(files.map(\.size), [32])
    }

    // MARK: - Permission denied

    /// The scanner must surface a clean result rather than throwing when
    /// some children are unreadable. We approximate this by chmod-ing a
    /// subdirectory to 0o000; the enumerator will hit EACCES on it but
    /// should keep walking the rest of the tree.
    func test_scan_handlesPermissionDeniedWithoutCrashing() async throws {
        let readable = tempRoot.appendingPathComponent("readable", isDirectory: true)
        let locked = tempRoot.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 2, size: 4, in: readable)
        try TestHelpers.createDummyFiles(count: 1, size: 4, in: locked)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: locked.path
        )
        // Restore perms in teardown order so cleanup can recurse into it.
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: locked.path
            )
        }

        let scanner = FileScanner()
        let files: [ScannedFile]
        do {
            files = try await scanner.scan(
                roots: [ScanRoot(url: tempRoot, category: .userCache)],
                excluding: []
            )
        } catch {
            XCTFail("Scanner threw on permission-denied: \(error)")
            return
        }
        XCTAssertGreaterThanOrEqual(files.count, 2, "Readable subtree should still be enumerated")
    }

    // MARK: - File metadata

    /// `ScannedFile.size` must match what the file system reports for the
    /// underlying file. Dummy files in `TestHelpers` are written with a
    /// known byte count; this pins the path through `URLResourceValues`.
    func test_scan_recordedFileSizeMatchesActualFileSize() async throws {
        try TestHelpers.createDummyFile(named: "exact.bin", size: 1_234, in: tempRoot)

        let scanner = FileScanner()
        let files = try await scanner.scan(
            roots: [ScanRoot(url: tempRoot, category: .userCache)],
            excluding: []
        )

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.size, 1_234)
    }
}
