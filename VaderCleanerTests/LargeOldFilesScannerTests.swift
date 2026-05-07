// LargeOldFilesScannerTests.swift
// Drives LargeOldFilesScanner against temp directories via an injected UserFilesPathProviding stub, covering size/age classification, the both-match tiebreak, the unknown-access-date guard, and exclusion forwarding.

import XCTest
@testable import VaderCleaner

/// Verifies `LargeOldFilesScanner` end-to-end. Like `SystemJunkScannerTests`,
/// we never touch the real `~/Documents` etc. — a `StubUserFilesPathProvider`
/// returns roots under a temp directory so the suite is hermetic and the
/// machine's actual user files never enter the picture.
final class LargeOldFilesScannerTests: XCTestCase {

    private var tempRoot: URL!

    /// Fixed "now" used to derive the cutoff. All age-bearing fixtures stamp
    /// their `contentAccessDate` relative to this so the assertions don't
    /// depend on real time.
    private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

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

    // MARK: - Size classification

    /// A file larger than the threshold must be returned tagged `.largeFile`.
    /// Sub-threshold files in the same root must be filtered out — the scanner
    /// is not a generic walker, it only emits files matching at least one
    /// criterion.
    func test_scan_findsFilesAboveSizeThreshold() async throws {
        let root = try makeRoot("documents")
        let large = try TestHelpers.createDummyFile(
            named: "big.bin",
            size: Int(LargeOldFilesScanner.sizeThresholdBytes) + 1,
            in: root
        )
        try TestHelpers.createDummyFile(named: "small.bin", size: 32, in: root)
        try setRecentAccessDate(at: large)

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(roots: [root]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertEqual(files.count, 1, "Only the > 50 MB file should be emitted")
        XCTAssertEqual(files.first?.url.lastPathComponent, "big.bin")
        XCTAssertEqual(files.first?.category, .largeFile)
    }

    // MARK: - Age classification

    /// A file last accessed before the cutoff must be returned tagged
    /// `.oldFile`. Recently accessed files in the same root must be filtered
    /// out so the user is not shown last week's downloads.
    func test_scan_findsFilesNotAccessedWithinAgeThreshold() async throws {
        let root = try makeRoot("downloads")
        let stale = try TestHelpers.createDummyFile(named: "stale.txt", size: 32, in: root)
        let fresh = try TestHelpers.createDummyFile(named: "fresh.txt", size: 32, in: root)
        try setAccessDate(at: stale,
                          to: referenceNow.addingTimeInterval(-LargeOldFilesScanner.ageThresholdSeconds - 86_400))
        try setAccessDate(at: fresh, to: referenceNow.addingTimeInterval(-3_600))

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(roots: [root]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertEqual(files.count, 1, "Only the stale file should be emitted")
        XCTAssertEqual(files.first?.url.lastPathComponent, "stale.txt")
        XCTAssertEqual(files.first?.category, .oldFile)
    }

    // MARK: - Both-match tiebreak

    /// A file that is both large AND old must be tagged `.largeFile` — size is
    /// a more deterministic signal than access date (which can be flaky on
    /// `noatime` mounts), so we prefer it. Documented inline in the scanner.
    func test_scan_classifiesLargeAndOldFileAsLargeFile() async throws {
        let root = try makeRoot("desktop")
        let huge = try TestHelpers.createDummyFile(
            named: "huge-and-stale.bin",
            size: Int(LargeOldFilesScanner.sizeThresholdBytes) + 1,
            in: root
        )
        try setAccessDate(at: huge,
                          to: referenceNow.addingTimeInterval(-LargeOldFilesScanner.ageThresholdSeconds - 86_400))

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(roots: [root]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.category, .largeFile,
                       "Tiebreak: a file matching both criteria is reported as .largeFile")
    }

    // MARK: - Unknown access date

    /// Files whose `lastAccessDate` is `nil` cannot be classified by age and,
    /// if also under the size threshold, must not be emitted at all. Mirrors
    /// the `ScannedFile` doc comment ("`nil` means 'unknown — don't classify
    /// by age'").
    func test_scan_skipsFilesWithUnknownAccessDateBelowSizeThreshold() async throws {
        // We can't synthesize a nil contentAccessDate from APFS in a test
        // (the FS always tracks one). Instead we drive the scanner through a
        // FakeFileScanner that emits a synthetic ScannedFile with nil dates,
        // proving the scanner's classification logic — not the file system —
        // is the gate.
        let synthetic = ScannedFile(
            url: URL(fileURLWithPath: "/tmp/large-old-tests/unknown.bin"),
            size: 32,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .largeFile
        )
        let scanner = LargeOldFilesScanner(
            fileScanner: FakeFileScanner(emitted: [synthetic]),
            pathProvider: StubUserFilesPathProvider(roots: [tempRoot]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertTrue(files.isEmpty,
                      "A small file with unknown access date matches neither criterion and must be dropped")
    }

    // MARK: - Exclusions

    /// `excluding:` is forwarded straight to the underlying `FileScanning`, so
    /// any path under an excluded URL must not appear in the result —
    /// regardless of whether it would have qualified as large or old.
    func test_scan_respectsExclusions() async throws {
        let root = try makeRoot("pictures")
        let kept = root.appendingPathComponent("kept", isDirectory: true)
        let excluded = root.appendingPathComponent("excluded", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        let keptLarge = try TestHelpers.createDummyFile(
            named: "kept-large.bin",
            size: Int(LargeOldFilesScanner.sizeThresholdBytes) + 1,
            in: kept
        )
        let excludedLarge = try TestHelpers.createDummyFile(
            named: "excluded-large.bin",
            size: Int(LargeOldFilesScanner.sizeThresholdBytes) + 1,
            in: excluded
        )
        try setRecentAccessDate(at: keptLarge)
        try setRecentAccessDate(at: excludedLarge)

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(roots: [root]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [excluded])

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.url.lastPathComponent, "kept-large.bin")
    }

    // MARK: - Helpers

    private func makeRoot(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stamps `url`'s `contentAccessDate` to a date well within the freshness
    /// window so size-bound tests don't accidentally trip the age path.
    private func setRecentAccessDate(at url: URL) throws {
        try setAccessDate(at: url, to: referenceNow.addingTimeInterval(-3_600))
    }

    /// Writes both `contentAccessDate` and `contentModificationDate` so the
    /// underlying file system honors the change even on `relatime`-style
    /// mounts that update atime opportunistically from mtime.
    private func setAccessDate(at url: URL, to date: Date) throws {
        var values = URLResourceValues()
        values.contentAccessDate = date
        values.contentModificationDate = date
        var mutable = url
        try mutable.setResourceValues(values)
    }
}

// MARK: - Stubs

/// Returns a fixed list of root URLs so tests can drive the scanner against a
/// temp directory rather than the real `~/Documents` etc.
private struct StubUserFilesPathProvider: UserFilesPathProviding {
    private let stubbedRoots: [URL]
    init(roots: [URL]) { self.stubbedRoots = roots }
    func roots() -> [URL] { stubbedRoots }
}

/// Lets `test_scan_skipsFilesWithUnknownAccessDateBelowSizeThreshold` synthesize
/// a `ScannedFile` with `lastAccessDate == nil` — APFS always populates that
/// timestamp, so we can't produce one through real I/O.
private struct FakeFileScanner: FileScanning {
    let emitted: [ScannedFile]
    func scan(roots: [ScanRoot], excluding: [URL]) async throws -> [ScannedFile] {
        emitted
    }
}
