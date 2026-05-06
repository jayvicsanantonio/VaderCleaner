// SystemJunkDeleterTests.swift
// Pins SystemJunkDeleter's user/system path routing rule and exercises the user-domain delete path against a temp directory; helper-domain calls are routed through an injected fake helper so no privileged XPC connection is required.

import XCTest
@testable import VaderCleaner

@MainActor
final class SystemJunkDeleterTests: XCTestCase {

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

    // MARK: - Path routing

    /// Anything under `/Library`, `/private/var`, `/System`, or `/Volumes`
    /// must be flagged as helper-only; anything else stays in-process. The
    /// rule lives on a static for testability — callers should not have to
    /// instantiate the deleter just to ask the question.
    func test_requiresHelper_recognisesSystemPrefixes() {
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/Library/Caches/foo"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/Library/Logs/bar.log"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/private/var/folders/abc"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/System/Library/Caches/x"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/Volumes/External/.Trashes/501/file"))
    }

    /// User-domain paths must never be routed through the helper — that would
    /// make the privileged tool do work the app could safely do itself, and
    /// would reject in dev environments where the helper isn't registered.
    func test_requiresHelper_rejectsUserDomainPaths() {
        XCTAssertFalse(SystemJunkDeleter.requiresHelper(path: "/Users/alice/Library/Caches/x"))
        XCTAssertFalse(SystemJunkDeleter.requiresHelper(path: "/Users/alice/.Trash/file"))
        XCTAssertFalse(SystemJunkDeleter.requiresHelper(path: "/tmp/whatever"))
    }

    // MARK: - User-domain deletion

    /// Files under the temp root (a user-writable location) must go through
    /// `FileManager.removeItem` and contribute their byte count to the
    /// returned freed-bytes total.
    func test_delete_userDomainFiles_removesAndReportsBytesFreed() async throws {
        let dir = tempRoot.appendingPathComponent("user-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try TestHelpers.createDummyFiles(count: 3, size: 100, in: dir)
        let files = urls.map {
            ScannedFile(url: $0, size: 100, lastAccessDate: nil, lastModifiedDate: nil, category: .userCache)
        }

        let deleter = SystemJunkDeleter(helperProvider: { nil })
        let bytesFreed = try await deleter.delete(files)

        XCTAssertEqual(bytesFreed, 300)
        for url in urls {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "Expected \(url.path) to be removed"
            )
        }
    }

    /// A nonexistent user-domain file must not abort the rest of the batch —
    /// a single locked or already-deleted log file is the most common
    /// failure mode and must not block the rest of the clean. The freed
    /// total reflects only the files that actually succeeded.
    func test_delete_skipsNonexistentUserFiles() async throws {
        let dir = tempRoot.appendingPathComponent("user-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let presentURL = try TestHelpers.createDummyFile(named: "real.bin", size: 50, in: dir)
        let absentURL = dir.appendingPathComponent("missing.bin")
        let files = [
            ScannedFile(url: presentURL, size: 50, lastAccessDate: nil, lastModifiedDate: nil, category: .userCache),
            ScannedFile(url: absentURL,  size: 9_999, lastAccessDate: nil, lastModifiedDate: nil, category: .userCache)
        ]

        let deleter = SystemJunkDeleter(helperProvider: { nil })
        let bytesFreed = try await deleter.delete(files)

        XCTAssertEqual(bytesFreed, 50, "Only the file that actually existed should contribute to bytesFreed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: presentURL.path))
    }

    // MARK: - Helper-domain deletion (routing only)

    /// When a system-path file is in the batch, the helper proxy must be
    /// asked to delete it. We don't run a real privileged helper here —
    /// instead, an injected `FakeHelper` records the paths it received so
    /// the test can assert the routing decision without launching XPC.
    func test_delete_systemPathRoutesThroughHelperAndCountsBytesOnSuccess() async throws {
        let userDir = tempRoot.appendingPathComponent("user-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let userURL = try TestHelpers.createDummyFile(named: "u.bin", size: 100, in: userDir)
        // System-path fixture URL — the file does not have to exist on disk;
        // the fake helper will accept any path it is handed.
        let systemURL = URL(fileURLWithPath: "/Library/Caches/com.bogus.test/file.bin")
        let files = [
            ScannedFile(url: userURL,   size: 100, lastAccessDate: nil, lastModifiedDate: nil, category: .userCache),
            ScannedFile(url: systemURL, size: 250, lastAccessDate: nil, lastModifiedDate: nil, category: .systemCache)
        ]

        let fakeHelper = FakeHelper(replyError: nil)
        let deleter = SystemJunkDeleter(helperProvider: { fakeHelper })
        let bytesFreed = try await deleter.delete(files)

        XCTAssertEqual(bytesFreed, 350, "Both user (100) and helper-credited system (250) bytes count")
        XCTAssertEqual(fakeHelper.receivedPaths, [systemURL.path])
    }

    /// If the helper reports an error, the system-path bytes must NOT be
    /// credited to the freed total — the protocol cannot tell us which
    /// paths succeeded, so we cannot honestly claim partial progress.
    /// User-domain bytes still count because we deleted those in-process.
    func test_delete_systemPathErrorDoesNotCreditBytes() async throws {
        let userDir = tempRoot.appendingPathComponent("user-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let userURL = try TestHelpers.createDummyFile(named: "u.bin", size: 50, in: userDir)
        let systemURL = URL(fileURLWithPath: "/Library/Caches/com.bogus.test/missing.bin")
        let files = [
            ScannedFile(url: userURL,   size: 50,  lastAccessDate: nil, lastModifiedDate: nil, category: .userCache),
            ScannedFile(url: systemURL, size: 999, lastAccessDate: nil, lastModifiedDate: nil, category: .systemCache)
        ]

        let fakeHelper = FakeHelper(replyError: NSError(domain: "test", code: 1))
        let deleter = SystemJunkDeleter(helperProvider: { fakeHelper })
        let bytesFreed = try await deleter.delete(files)

        XCTAssertEqual(bytesFreed, 50, "Only user-domain bytes should be credited when the helper batch failed")
    }

    /// When the helper is unavailable (typical dev environment without ad-hoc
    /// signing), system-path deletion must not credit bytes — but the user-
    /// domain side of the batch must still go through. This is the most
    /// common case during local development.
    func test_delete_unavailableHelperFallsBackToUserOnlyDelete() async throws {
        let userDir = tempRoot.appendingPathComponent("user-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let userURL = try TestHelpers.createDummyFile(named: "u.bin", size: 75, in: userDir)
        let systemURL = URL(fileURLWithPath: "/Library/Caches/com.bogus.test/x.bin")
        let files = [
            ScannedFile(url: userURL,   size: 75,  lastAccessDate: nil, lastModifiedDate: nil, category: .userCache),
            ScannedFile(url: systemURL, size: 999, lastAccessDate: nil, lastModifiedDate: nil, category: .systemCache)
        ]

        let deleter = SystemJunkDeleter(helperProvider: { nil })
        let bytesFreed = try await deleter.delete(files)

        XCTAssertEqual(bytesFreed, 75)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userURL.path))
    }
}

// MARK: - Test doubles

/// Minimal `VaderCleanerHelperProtocol` stand-in — captures the paths it was
/// asked to delete and replies with the supplied error (or nil for success).
/// Inherits from `NSObject` because the underlying protocol is `@objc`.
private final class FakeHelper: NSObject, VaderCleanerHelperProtocol {
    private let replyError: Error?
    private(set) var receivedPaths: [String] = []

    init(replyError: Error?) {
        self.replyError = replyError
    }

    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {
        receivedPaths = paths
        reply(replyError)
    }

    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) { reply(nil) }
}
