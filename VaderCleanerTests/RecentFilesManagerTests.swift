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
        let recents       = sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments.sfl3")
        let apps          = sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentApplications.sfl3")
        let hosts         = sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentHosts.sfl3")
        // SFL-prefix sibling that is *not* a Recents list — the
        // original test used a totally unrelated `.plist` which couldn't
        // distinguish "only Recent* sfl files removed" from "every sfl
        // file removed". Favorites is the canonical non-Recent SFL file.
        let favorites     = sharedDir.appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems.sfl3")
        // Prefix-only file that lacks an `.sfl*` suffix — exercises the
        // tightened filter that requires both prefix and suffix.
        let prefixOnly    = sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments.config.plist")
        // Unrelated entry, retained to prove the filter doesn't sweep
        // non-SFL files in the same directory either.
        let other         = sharedDir.appendingPathComponent("com.apple.SomethingElse.plist")
        for url in [recents, apps, hosts, favorites, prefixOnly, other] {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: favorites.path),
                      "Non-Recent SFL entries (FavoriteItems) must be left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefixOnly.path),
                      "Files with the Recent prefix but not an .sfl* suffix must be left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path),
                      "Unrelated entries must be left alone")
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
