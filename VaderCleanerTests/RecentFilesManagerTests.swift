// RecentFilesManagerTests.swift
// Verifies that RecentFilesManager invokes both the per-app and system-wide clear actions exactly once when asked to clear, and removes any sharedfilelist sfl files reachable under the injected home directory.

import XCTest
@testable import VaderCleaner

@MainActor
final class RecentFilesManagerTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = try TestHelpers.createTempDirectory()
    }

    override func tearDownWithError() throws {
        TestHelpers.tearDownTempDirectory(tempHome)
        tempHome = nil
        try super.tearDownWithError()
    }

    /// `clear()` must invoke the injected app-level clear action exactly
    /// once. The closure indirection exists so production can wrap
    /// `NSDocumentController.shared.clearRecentDocuments(_:)` (global
    /// state, awkward to assert against) while tests count invocations
    /// without touching that singleton.
    func test_clear_invokesAppLevelClearActionOnce() throws {
        var invocations = 0
        let manager = RecentFilesManager(
            homeDirectory: tempHome,
            clearAppRecentDocuments: { invocations += 1 }
        )

        try manager.clear()

        XCTAssertEqual(invocations, 1)
    }

    /// `clear()` must remove every `com.apple.LSSharedFileList.Recent*.sfl*`
    /// file that exists under
    /// `~/Library/Application Support/com.apple.sharedfilelist/`. These plist
    /// files are the on-disk source of truth for the Apple-menu Recent
    /// Items list — clearing only `NSDocumentController` (which targets
    /// just this app's recent docs) would leave the user-visible global
    /// list untouched.
    func test_clear_removesSharedFileListRecentEntries() throws {
        let sharedDir = tempHome
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let recents = sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments.sfl3")
        let apps    = sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentApplications.sfl3")
        let hosts   = sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentHosts.sfl3")
        let other   = sharedDir.appendingPathComponent("com.apple.SomethingElse.plist")
        for url in [recents, apps, hosts, other] {
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 8))
        }

        let manager = RecentFilesManager(
            homeDirectory: tempHome,
            clearAppRecentDocuments: { }
        )

        try manager.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: recents.path), "Recents sfl should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: apps.path),    "Recent apps sfl should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hosts.path),   "Recent hosts sfl should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path),
                      "Non-Recent* sfl entries must be left alone")
    }

    /// When the sharedfilelist directory is missing entirely, `clear()`
    /// must not throw — a fresh user account that's never opened a
    /// document has no list to clear, and that's still a successful "clear
    /// recent items" result.
    func test_clear_doesNotThrowWhenSharedFileListDirectoryIsMissing() throws {
        let manager = RecentFilesManager(
            homeDirectory: tempHome,
            clearAppRecentDocuments: { }
        )
        XCTAssertNoThrow(try manager.clear())
    }
}
