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

    /// Anything under `/Library`, `/private/var`, `/System`, or `/Applications`,
    /// plus per-volume `.Trashes/<uid>/...` under `/Volumes/...`, must be
    /// flagged as helper-only. The rule lives on a static for testability —
    /// callers should not have to instantiate the deleter just to ask the
    /// question.
    func test_requiresHelper_recognisesSystemPrefixes() {
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/Library/Caches/foo"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/Library/Logs/bar.log"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/private/var/folders/abc"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/System/Library/Caches/x"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/Volumes/External/.Trashes/501/file"))
    }

    /// The Document Versions store (`/.DocumentRevisions-V100`) is owned by
    /// root, so deleting saved revisions inside it must go through the helper —
    /// an in-process `removeItem` would silently fail. Covers both the firmlink
    /// at the data-volume root and the `/System/Volumes/Data` spelling (already
    /// helper-only via the `/System/` prefix).
    func test_requiresHelper_routesDocumentVersionsThroughHelper() {
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/.DocumentRevisions-V100/PerUID/501/x/abc"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/System/Volumes/Data/.DocumentRevisions-V100/PerUID/501/x"))
    }

    /// `/Applications` is owned by `root:wheel` on a default macOS install
    /// and most system-installed `.app` bundles inside it are not writable
    /// by the user process, so language-file pruning under them must go
    /// through the helper. Reported by Codex review on PR #30.
    func test_requiresHelper_routesSystemInstalledAppsThroughHelper() {
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/Applications/Safari.app/Contents/Resources/nl.lproj/Localizable.strings"))
        XCTAssertTrue(SystemJunkDeleter.requiresHelper(path: "/Applications/Some.app/Contents/Resources/de.lproj/InfoPlist.strings"))
    }

    /// User-domain paths must never be routed through the helper — that would
    /// make the privileged tool do work the app could safely do itself, and
    /// would reject in dev environments where the helper isn't registered.
    /// Includes a regression case for the previous "every `/Volumes/...` is
    /// helper-only" behaviour: a plain file on a mounted external drive is
    /// user-writable and stays in-process. Reported by CodeRabbit review on
    /// PR #30.
    func test_requiresHelper_rejectsUserDomainPaths() {
        XCTAssertFalse(SystemJunkDeleter.requiresHelper(path: "/Users/alice/Library/Caches/x"))
        XCTAssertFalse(SystemJunkDeleter.requiresHelper(path: "/Users/alice/.Trash/file"))
        XCTAssertFalse(SystemJunkDeleter.requiresHelper(path: "/Users/alice/Applications/MyApp.app/Contents/Resources/de.lproj/x"))
        XCTAssertFalse(SystemJunkDeleter.requiresHelper(path: "/tmp/whatever"))
        XCTAssertFalse(SystemJunkDeleter.requiresHelper(path: "/Volumes/External/Movies/clip.mov"))
    }

    /// Home-Trash items are emptied permanently; everything else user-domain
    /// goes to the Trash (recoverable). Mounted-volume trashes are helper-routed,
    /// not matched here.
    func test_isInUserTrash_matchesHomeTrashOnly() {
        XCTAssertTrue(SystemJunkDeleter.isInUserTrash(path: "/Users/alice/.Trash/old.dmg"))
        XCTAssertFalse(SystemJunkDeleter.isInUserTrash(path: "/Users/alice/Library/Caches/x"))
        XCTAssertFalse(SystemJunkDeleter.isInUserTrash(path: "/Volumes/External/.Trashes/501/y"))
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

        let deleter = SystemJunkDeleter(helperProvider: { _ in nil })
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

        let deleter = SystemJunkDeleter(helperProvider: { _ in nil })
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
        let deleter = SystemJunkDeleter(helperProvider: { _ in fakeHelper })
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
        let deleter = SystemJunkDeleter(helperProvider: { _ in fakeHelper })
        let bytesFreed = try await deleter.delete(files)

        XCTAssertEqual(bytesFreed, 50, "Only user-domain bytes should be credited when the helper batch failed")
    }

    /// Regression test for the XPC continuation hang reported on PR #30:
    /// when the privileged helper fires its connection-level error handler
    /// **instead of** invoking the per-call reply block (the way
    /// `NSXPCConnection` reports interrupted/invalidated connections),
    /// `delete()` must still resolve — not leave `clean()` stuck on the
    /// `.cleaning` spinner forever. We simulate that by dropping the reply
    /// block on the floor and using the per-call error handler that the
    /// new `helperProvider` signature exposes.
    func test_delete_resumesWhenHelperConnectionErrorFiresInsteadOfReply() async throws {
        let systemURL = URL(fileURLWithPath: "/Library/Caches/com.bogus.test/file.bin")
        let files = [
            ScannedFile(url: systemURL, size: 999, lastAccessDate: nil, lastModifiedDate: nil, category: .systemCache)
        ]

        // Deleter that never replies — only the error handler fires. Without
        // the per-call error sink, `withCheckedContinuation` would never
        // resume and this test would time out under XCTest's default cap.
        let droppingHelper = DroppingReplyHelper()
        let deleter = SystemJunkDeleter(helperProvider: { errorHandler in
            // Simulate XPC delivering a connection-level error.
            errorHandler(NSError(domain: "test.xpc", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Connection invalidated"
            ]))
            return droppingHelper
        })

        let bytesFreed = try await deleter.delete(files)

        XCTAssertEqual(bytesFreed, 0, "Connection error must resolve as failure, not hang")
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

        let deleter = SystemJunkDeleter(helperProvider: { _ in nil })
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
    func flushDNSCache(reply: @escaping (Error?) -> Void) { reply(nil) }
    func reindexSpotlight(reply: @escaping (Error?) -> Void) { reply(nil) }
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) { reply(nil) }
    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void) { reply([], [], nil) }
}

/// Helper stand-in that intentionally drops the reply block on the floor —
/// models the real `NSXPCConnection` failure mode where the connection-level
/// error handler fires instead of the per-call reply. The test confirms the
/// awaiting `delete()` resolves anyway, via the per-call error sink.
private final class DroppingReplyHelper: NSObject, VaderCleanerHelperProtocol {
    func deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void) {
        // Intentionally no `reply(...)`.
    }
    func runMaintenanceScripts(reply: @escaping (Error?) -> Void) {}
    func removeLoginItem(path: String, reply: @escaping (Error?) -> Void) {}
    func removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void) {}
    func flushInactiveMemory(reply: @escaping (Error?) -> Void) {}
    func flushDNSCache(reply: @escaping (Error?) -> Void) {}
    func reindexSpotlight(reply: @escaping (Error?) -> Void) {}
    func thinTimeMachineSnapshots(reply: @escaping (Error?) -> Void) {}
    func scanDocumentVersions(reply: @escaping ([String], [NSNumber], Error?) -> Void) {}
}
