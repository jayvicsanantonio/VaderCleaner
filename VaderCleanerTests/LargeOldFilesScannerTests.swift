// LargeOldFilesScannerTests.swift
// Drives LargeOldFilesScanner against temp directories via an injected UserFilesPathProviding stub, covering size/age classification, the both-match tiebreak, the unknown-access-date guard, exclusion forwarding, and protected-media-store skipping, plus DefaultUserFilesPathProvider.protectedMediaStores discovery.

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

    func test_scan_emitsLargePackageAsSingleLargeFile() async throws {
        let root = try makeRoot("applications")
        let package = root.appendingPathComponent("Archive.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let innerFile = contents.appendingPathComponent("payload.bin")
        try createSparseFile(at: innerFile, size: LargeOldFilesScanner.sizeThresholdBytes + 1)

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(roots: [root]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.url.resolvingSymlinksInPath().path, package.resolvingSymlinksInPath().path)
        XCTAssertEqual(files.first?.size, LargeOldFilesScanner.sizeThresholdBytes + 1)
        XCTAssertEqual(files.first?.category, .largeFile)
        XCTAssertFalse(
            files.contains {
                $0.url.resolvingSymlinksInPath().path == innerFile.resolvingSymlinksInPath().path
            },
            "Package internals should not leak as separate large-file rows"
        )
    }

    func test_scan_usesPackageContentAccessDateForAgeClassification() async throws {
        let root = try makeRoot("applications")
        // A plain `.app` package — not a TCC-protected media store, so the
        // scanner rolls it up and the package content-access-date path is
        // actually exercised here.
        let package = root.appendingPathComponent("LegacyArchive.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let innerFile = try TestHelpers.createDummyFile(named: "active.sqlite", size: 32, in: contents)
        try setAccessDate(at: innerFile, to: referenceNow.addingTimeInterval(-3_600))
        try setAccessDate(
            at: package,
            to: referenceNow.addingTimeInterval(-LargeOldFilesScanner.ageThresholdSeconds - 86_400)
        )

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(roots: [root]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertTrue(files.isEmpty, "Fresh package contents should keep a small package out of old-file results")
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

    /// A file last accessed *exactly* at the cutoff must be classified as
    /// `.oldFile` — the comparison is inclusive (`<=`) so users on
    /// coarse-resolution file systems aren't told a six-month-old file is
    /// "still fresh" because the cutoff happened to land on the same
    /// timestamp. Locks the boundary semantics so future refactors don't
    /// silently flip the behavior.
    func test_scan_classifiesFileAccessedExactlyAtCutoffAsOld() async throws {
        let root = try makeRoot("documents-boundary")
        let edge = try TestHelpers.createDummyFile(named: "edge.txt", size: 32, in: root)
        let cutoff = referenceNow.addingTimeInterval(-LargeOldFilesScanner.ageThresholdSeconds)
        try setAccessDate(at: edge, to: cutoff)

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(roots: [root]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertEqual(files.count, 1, "Cutoff is inclusive: a file at the exact threshold counts as old")
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

    func test_scan_filtersBatchesWithoutReturningNonMatches() async throws {
        let nonMatchingFiles = (0..<1_000).map { index in
            ScannedFile(
                url: URL(fileURLWithPath: "/tmp/large-old-tests/small-\(index).txt"),
                size: 32,
                lastAccessDate: referenceNow.addingTimeInterval(-3_600),
                lastModifiedDate: nil,
                category: .largeFile
            )
        }
        let matchingFile = ScannedFile(
            url: URL(fileURLWithPath: "/tmp/large-old-tests/match.bin"),
            size: LargeOldFilesScanner.sizeThresholdBytes + 1,
            lastAccessDate: referenceNow.addingTimeInterval(-3_600),
            lastModifiedDate: nil,
            category: .largeFile
        )
        let fakeScanner = FakeFileScanner(emittedBatches: [
            Array(nonMatchingFiles.prefix(500)),
            Array(nonMatchingFiles.suffix(500)) + [matchingFile]
        ])
        let scanner = LargeOldFilesScanner(
            fileScanner: fakeScanner,
            pathProvider: StubUserFilesPathProvider(roots: [tempRoot]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertEqual(files, [matchingFile])
    }

    func test_scanBatchAPI_emitsOnlyMatchingFilesPerUnderlyingBatch() async throws {
        let nonMatchingFile = ScannedFile(
            url: URL(fileURLWithPath: "/tmp/large-old-tests/small.txt"),
            size: 32,
            lastAccessDate: referenceNow.addingTimeInterval(-3_600),
            lastModifiedDate: nil,
            category: .largeFile
        )
        let largeFile = ScannedFile(
            url: URL(fileURLWithPath: "/tmp/large-old-tests/large.bin"),
            size: LargeOldFilesScanner.sizeThresholdBytes + 1,
            lastAccessDate: referenceNow.addingTimeInterval(-3_600),
            lastModifiedDate: nil,
            category: .largeFile
        )
        let oldFile = ScannedFile(
            url: URL(fileURLWithPath: "/tmp/large-old-tests/old.txt"),
            size: 32,
            lastAccessDate: referenceNow.addingTimeInterval(-LargeOldFilesScanner.ageThresholdSeconds - 86_400),
            lastModifiedDate: nil,
            category: .largeFile
        )
        let fakeScanner = FakeFileScanner(emittedBatches: [
            [nonMatchingFile, largeFile],
            [oldFile]
        ])
        let scanner = LargeOldFilesScanner(
            fileScanner: fakeScanner,
            pathProvider: StubUserFilesPathProvider(roots: [tempRoot]),
            now: { self.referenceNow }
        )
        var emittedBatches: [[ScannedFile]] = []

        try await scanner.scan(excluding: [], batchSize: 2) { batch in
            emittedBatches.append(batch)
        }

        XCTAssertEqual(emittedBatches, [
            [largeFile],
            [
                ScannedFile(
                    url: oldFile.url,
                    size: oldFile.size,
                    lastAccessDate: oldFile.lastAccessDate,
                    lastModifiedDate: oldFile.lastModifiedDate,
                    category: .oldFile
                )
            ]
        ])
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

    // MARK: - Protected media stores

    /// TCC-protected photo-library bundles (`.photoslibrary`, `Photo Booth
    /// Library`) are skipped by `FileScanner` during the walk — at any depth,
    /// in any root — so they never surface as deletable large files and the
    /// scan never descends into one (which would trip a macOS Photos prompt).
    func test_scan_excludesProtectedMediaStores() async throws {
        let root = try makeRoot("pictures")

        let topLibrary = root.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
        let nestedLibrary = root
            .appendingPathComponent("Archive", isDirectory: true)
            .appendingPathComponent("Old Trips.photoslibrary", isDirectory: true)
        for library in [topLibrary, nestedLibrary] {
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try createSparseFile(
                at: library.appendingPathComponent("originals.bin"),
                size: LargeOldFilesScanner.sizeThresholdBytes + 1
            )
        }

        let keptLarge = try TestHelpers.createDummyFile(
            named: "kept-large.bin",
            size: Int(LargeOldFilesScanner.sizeThresholdBytes) + 1,
            in: root
        )
        try setRecentAccessDate(at: keptLarge)

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(roots: [root]),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertEqual(
            files.map { $0.url.lastPathComponent },
            ["kept-large.bin"],
            "Protected photo libraries must not surface as large files, at any depth"
        )
    }

    /// Paths from `pathProvider.protectedMediaStores()` — the fixed-path Apple
    /// Music / iTunes folders — are folded into the scan's exclusion list, so
    /// nothing under them is emitted.
    func test_scan_excludesProtectedMediaStorePaths() async throws {
        let root = try makeRoot("music")
        let mediaFolder = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        let insideMedia = try TestHelpers.createDummyFile(
            named: "track.bin",
            size: Int(LargeOldFilesScanner.sizeThresholdBytes) + 1,
            in: mediaFolder
        )
        try setRecentAccessDate(at: insideMedia)
        let keptLarge = try TestHelpers.createDummyFile(
            named: "kept-large.bin",
            size: Int(LargeOldFilesScanner.sizeThresholdBytes) + 1,
            in: root
        )
        try setRecentAccessDate(at: keptLarge)

        let scanner = LargeOldFilesScanner(
            pathProvider: StubUserFilesPathProvider(
                roots: [root],
                protectedMediaStores: [mediaFolder]
            ),
            now: { self.referenceNow }
        )

        let files = try await scanner.scan(excluding: [])

        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["kept-large.bin"])
    }

    // MARK: - DefaultUserFilesPathProvider protected media stores

    /// `protectedMediaStores()` returns the fixed-path Apple Music and legacy
    /// iTunes media folders — and *only* those. Photo-library bundles are not
    /// pre-discovered here; `FileScanner` skips them in-walk instead.
    func test_protectedMediaStores_returnsOnlyTheFixedPathMusicFolders() throws {
        let pictures = tempRoot.appendingPathComponent("Pictures", isDirectory: true)
        let music = tempRoot.appendingPathComponent("Music", isDirectory: true)
        let photoLibrary = pictures.appendingPathComponent("Family.photoslibrary", isDirectory: true)
        let appleMusic = music.appendingPathComponent("Music", isDirectory: true)
        let iTunes = music.appendingPathComponent("iTunes", isDirectory: true)
        for directory in [photoLibrary, appleMusic, iTunes] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let provider = DefaultUserFilesPathProvider(homeDirectory: tempRoot)
        let stores = Set(provider.protectedMediaStores().map { $0.resolvingSymlinksInPath().path })

        XCTAssertEqual(
            stores,
            [appleMusic.resolvingSymlinksInPath().path, iTunes.resolvingSymlinksInPath().path],
            "Only the fixed-path Music folders belong here — photo libraries are skipped in-walk"
        )
    }

    /// The Apple Music and legacy iTunes folders sit at fixed paths but may not
    /// exist; `protectedMediaStores()` returns only folders that are actually
    /// present so the exclusion list never carries phantom paths.
    func test_protectedMediaStores_omitsMusicFoldersThatDoNotExist() throws {
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("Pictures", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("Music", isDirectory: true),
            withIntermediateDirectories: true
        )

        let provider = DefaultUserFilesPathProvider(homeDirectory: tempRoot)

        XCTAssertTrue(
            provider.protectedMediaStores().isEmpty,
            "An empty Pictures and Music layout has no protected media stores"
        )
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

    private func createSparseFile(at url: URL, size: Int64) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }
}

// MARK: - Stubs

/// Returns a fixed list of root URLs so tests can drive the scanner against a
/// temp directory rather than the real `~/Documents` etc.
private struct StubUserFilesPathProvider: UserFilesPathProviding {
    private let stubbedRoots: [URL]
    private let stubbedProtectedMediaStores: [URL]

    init(roots: [URL], protectedMediaStores: [URL] = []) {
        self.stubbedRoots = roots
        self.stubbedProtectedMediaStores = protectedMediaStores
    }

    func roots() -> [URL] { stubbedRoots }
    func protectedMediaStores() -> [URL] { stubbedProtectedMediaStores }
}

/// Lets `test_scan_skipsFilesWithUnknownAccessDateBelowSizeThreshold` synthesize
/// a `ScannedFile` with `lastAccessDate == nil` — APFS always populates that
/// timestamp, so we can't produce one through real I/O.
private struct FakeFileScanner: FileScanning {
    let emittedBatches: [[ScannedFile]]

    init(emitted: [ScannedFile]) {
        self.emittedBatches = [emitted]
    }

    init(emittedBatches: [[ScannedFile]]) {
        self.emittedBatches = emittedBatches
    }

    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        options: FileScanOptions,
        batchSize: Int,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws {
        for batch in emittedBatches {
            try await onBatch(batch)
        }
    }
}
