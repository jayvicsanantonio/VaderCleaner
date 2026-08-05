// PathSizerTests.swift
// Pins the one recursive-size policy every scanner shares: hidden files count, symlinks don't, and an unreadable child never zeros the total.

import XCTest
@testable import VaderCleaner

final class PathSizerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = try TestHelpers.createTempDirectory()
    }

    override func tearDown() async throws {
        TestHelpers.tearDownTempDirectory(tempRoot)
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Basics

    func test_size_ofMissingPath_isZero() {
        let missing = tempRoot.appendingPathComponent("nothing-here")
        XCTAssertEqual(PathSizer.size(at: missing, fileManager: .default), 0)
    }

    func test_size_ofRegularFile_isItsOwnSize() throws {
        let file = tempRoot.appendingPathComponent("one.bin")
        try Data(repeating: 0xAB, count: 4_096).write(to: file)
        XCTAssertEqual(PathSizer.size(at: file, fileManager: .default), 4_096)
    }

    func test_size_ofDirectory_sumsRegularFileDescendants() throws {
        try TestHelpers.createDummyFiles(count: 3, size: 1_000, in: tempRoot)
        XCTAssertEqual(PathSizer.size(at: tempRoot, fileManager: .default), 3_000)
    }

    func test_size_recursesIntoNestedDirectories() throws {
        let nested = tempRoot
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 2, size: 512, in: tempRoot)
        try TestHelpers.createDummyFiles(count: 2, size: 512, in: nested)
        XCTAssertEqual(PathSizer.size(at: tempRoot, fileManager: .default), 2_048)
    }

    // MARK: - The policy that had drifted

    /// The scanners disagreed here: some passed `.skipsHiddenFiles`, one did
    /// not, so the same folder reported two sizes on two screens. Deletion
    /// removes the whole tree, so excluding dotfiles understates what the user
    /// actually reclaims — on a real `~/Library/Application Support` entry that
    /// gap measured 17%.
    func test_size_countsHiddenFiles() throws {
        try TestHelpers.createDummyFiles(count: 1, size: 1_000, in: tempRoot)
        try Data(repeating: 0xCD, count: 500).write(to: tempRoot.appendingPathComponent(".hidden.bin"))
        XCTAssertEqual(PathSizer.size(at: tempRoot, fileManager: .default), 1_500)
    }

    func test_size_descendsIntoHiddenDirectories() throws {
        let hiddenDir = tempRoot.appendingPathComponent(".cache", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 2, size: 750, in: hiddenDir)
        XCTAssertEqual(PathSizer.size(at: tempRoot, fileManager: .default), 1_500)
    }

    /// A hidden file is the whole content here, so a sizer that skipped hidden
    /// entries would report an empty folder for one holding real bytes.
    func test_size_ofDirectoryHoldingOnlyHiddenFiles_isNotZero() throws {
        try Data(repeating: 0xEF, count: 2_048).write(to: tempRoot.appendingPathComponent(".only.bin"))
        XCTAssertEqual(PathSizer.size(at: tempRoot, fileManager: .default), 2_048)
    }

    // MARK: - Symlinks

    /// Symlinks are not regular files and are never followed: counting one
    /// would double-count its target, and following a directory link could
    /// walk clean out of the tree being measured.
    func test_size_ignoresSymlinkToFile() throws {
        let real = tempRoot.appendingPathComponent("real.bin")
        try Data(repeating: 0x01, count: 1_000).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: tempRoot.appendingPathComponent("link.bin"),
            withDestinationURL: real
        )
        XCTAssertEqual(PathSizer.size(at: tempRoot, fileManager: .default), 1_000)
    }

    func test_size_doesNotFollowSymlinkedDirectory() throws {
        let outside = try TestHelpers.createTempDirectory()
        defer { TestHelpers.tearDownTempDirectory(outside) }
        try TestHelpers.createDummyFiles(count: 4, size: 4_096, in: outside)

        try TestHelpers.createDummyFiles(count: 1, size: 100, in: tempRoot)
        try FileManager.default.createSymbolicLink(
            at: tempRoot.appendingPathComponent("elsewhere", isDirectory: true),
            withDestinationURL: outside
        )
        XCTAssertEqual(PathSizer.size(at: tempRoot, fileManager: .default), 100)
    }

    /// Passing the symlink itself, rather than finding one during a walk, is
    /// still not a file we own — it contributes nothing.
    func test_size_ofSymlinkPathItself_isZero() throws {
        let real = tempRoot.appendingPathComponent("target.bin")
        try Data(repeating: 0x02, count: 900).write(to: real)
        let link = tempRoot.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(PathSizer.size(at: link, fileManager: .default), 0)
    }

    // MARK: - Tolerance

    /// An unreadable child must not zero the row — a permission failure on one
    /// nested resource is normal (sandboxed XPC services, for one) and the
    /// surrounding total is still worth showing.
    func test_size_toleratesUnreadableChildDirectory() throws {
        let readable = tempRoot.appendingPathComponent("readable", isDirectory: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 2, size: 1_024, in: readable)

        let blocked = tempRoot.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try TestHelpers.createDummyFiles(count: 1, size: 5_000, in: blocked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        }

        XCTAssertGreaterThanOrEqual(PathSizer.size(at: tempRoot, fileManager: .default), 2_048)
    }

    // MARK: - Interruptible walk

    private struct StopWalking: Error {}

    /// The checkpoint runs per entry, so a large tree aborts partway through
    /// rather than only between top-level paths. `BrowserDataClearer` passes
    /// `Task.checkCancellation` here.
    func test_size_propagatesCheckpointError() throws {
        try TestHelpers.createDummyFiles(count: 10, size: 100, in: tempRoot)
        var calls = 0
        XCTAssertThrowsError(
            try PathSizer.size(at: tempRoot, fileManager: .default) {
                calls += 1
                if calls > 3 { throw StopWalking() }
            }
        ) { error in
            XCTAssertTrue(error is StopWalking)
        }
        XCTAssertLessThan(calls, 10, "the walk must stop at the checkpoint, not run to completion")
    }

    /// A non-throwing checkpoint leaves the call non-throwing — that is what
    /// `rethrows` buys, and why the plain overload needs no `try`.
    func test_size_withNonThrowingCheckpoint_matchesPlainWalk() throws {
        try TestHelpers.createDummyFiles(count: 4, size: 256, in: tempRoot)
        var calls = 0
        let checkpointed = PathSizer.size(at: tempRoot, fileManager: .default) { calls += 1 }
        XCTAssertEqual(checkpointed, PathSizer.size(at: tempRoot, fileManager: .default))
        XCTAssertGreaterThan(calls, 0)
    }

    func test_size_ofEmptyDirectory_isZero() throws {
        let empty = tempRoot.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(PathSizer.size(at: empty, fileManager: .default), 0)
    }
}
