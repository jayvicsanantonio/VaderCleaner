// LargeOldFilesClassificationTests.swift
// Pins what earns a file a place in Large & Old: every sign of recent use keeps it out, tiny files never qualify as old, cloud-only placeholders are skipped, and the default scope leaves ~/Library alone.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite struct LargeOldFilesClassificationTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var longAgo: Date { now.addingTimeInterval(-LargeOldFilesScanner.ageThresholdSeconds - 86_400) }
    private var recently: Date { now.addingTimeInterval(-3_600) }
    private let url = URL(fileURLWithPath: "/tmp/large-old-tests/file.bin")

    private func classify(
        size: Int64 = LargeOldFilesScanner.oldFileMinimumBytes,
        accessed: Date?,
        modified: Date?,
        lastUsed: Date? = nil,
        isLocal: Bool = true
    ) async throws -> [ScannedFile] {
        let file = ScannedFile(url: url, size: size, lastAccessDate: accessed, lastModifiedDate: modified, category: .largeFile)
        let scanner = LargeOldFilesScanner(
            fileScanner: OneFileScanner(file: file),
            pathProvider: OneRootProvider(root: url.deletingLastPathComponent()),
            now: { now },
            lastUsedDate: { _ in lastUsed },
            isLocallyAvailable: { _ in isLocal }
        )
        return try await scanner.scan(excluding: [])
    }

    @Test func aFileWithNoSignOfRecentUseIsOld() async throws {
        let files = try await classify(accessed: longAgo, modified: longAgo)
        #expect(files.map(\.category) == [.oldFile])
    }

    /// APFS leaves the access date alone once it is newer than the modified date,
    /// so a file read daily can show one from years ago. Spotlight's last-opened
    /// date is the signal that survives.
    @Test func aFileOpenedRecentlyIsNotOldHoweverStaleItsAccessDate() async throws {
        let files = try await classify(accessed: longAgo, modified: longAgo, lastUsed: recently)
        #expect(files.isEmpty)
    }

    @Test func aFileModifiedRecentlyIsNotOld() async throws {
        let files = try await classify(accessed: longAgo, modified: recently)
        #expect(files.isEmpty)
    }

    /// A file last opened long ago is still old: the date only rescues recent use.
    @Test func aLongAgoLastOpenedDateStaysOld() async throws {
        let files = try await classify(accessed: longAgo, modified: longAgo, lastUsed: longAgo)
        #expect(files.map(\.category) == [.oldFile])
    }

    @Test func aTinyFileIsNeverClutterForBeingOld() async throws {
        let files = try await classify(size: LargeOldFilesScanner.oldFileMinimumBytes - 1, accessed: longAgo, modified: longAgo)
        #expect(files.isEmpty)
    }

    @Test func aLargeFileStaysListedWhateverItsDates() async throws {
        let files = try await classify(size: LargeOldFilesScanner.sizeThresholdBytes + 1, accessed: recently, modified: recently, lastUsed: recently)
        #expect(files.map(\.category) == [.largeFile])
    }

    /// A cloud-only placeholder reports its full logical size but occupies no
    /// local space, and Trashing it removes the real file from iCloud.
    @Test func aCloudOnlyPlaceholderIsNeverListed() async throws {
        let large = try await classify(size: LargeOldFilesScanner.sizeThresholdBytes + 1, accessed: recently, modified: recently, isLocal: false)
        let old = try await classify(accessed: longAgo, modified: longAgo, isLocal: false)
        #expect(large.isEmpty)
        #expect(old.isEmpty)
    }

    /// `~/Library` holds live app data — message and mail databases, keychains —
    /// that a size or age rule can't tell from clutter.
    @Test func theDefaultScopeLeavesLibraryAlone() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let roots = DefaultUserFilesPathProvider(homeDirectory: home).roots().map(\.lastPathComponent)
        #expect(roots == ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures"])
    }

    @Test func aPickedFolderIsWalkedEvenInsideLibrary() {
        let picked = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Old App")
        let provider = DefaultUserFilesPathProvider(homeDirectory: URL(fileURLWithPath: "/Users/someone"), roots: [picked])
        #expect(provider.roots() == [picked])
    }
}

private struct OneFileScanner: FileScanning {
    let file: ScannedFile

    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        options: FileScanOptions,
        batchSize: Int,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws {
        try await onBatch([file])
    }
}

private struct OneRootProvider: UserFilesPathProviding {
    let root: URL
    func roots() -> [URL] { [root] }
    func protectedMediaStores() -> [URL] { [] }
}
