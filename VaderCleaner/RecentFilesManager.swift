// RecentFilesManager.swift
// Clears the macOS recent-items lists — both this app's NSDocumentController list and the system-wide Recent* sharedfilelist plists that drive the Apple-menu Recent Items.

import AppKit
import Foundation
import os.log

/// Clears the user's recently-opened files list.
///
/// macOS records "recent items" in two places:
///
///   1. Per-app via `NSDocumentController.shared.recentDocumentURLs`,
///      cleared with `clearRecentDocuments(_:)`. Targets this app's own
///      list; for VaderCleaner that list is empty (we're not document-
///      based), but we still call it so users on document-based apps that
///      adopt this pattern get the obvious behavior.
///   2. System-wide via plists under
///      `~/Library/Application Support/com.apple.sharedfilelist/`,
///      named `com.apple.LSSharedFileList.Recent*.sfl3` (and `sfl2` on
///      older macOS). These files are the on-disk source of truth for
///      the Apple-menu Recent Items list — clearing them empties the
///      menu after relogin / Dock restart.
///
/// The app-level clear action is injected as a closure so tests can verify
/// invocation without touching `NSDocumentController`'s singleton state.
@MainActor
struct RecentFilesManager {

    private let homeDirectory: URL
    private let fileManager: FileManager
    private let clearAppRecentDocuments: @MainActor () -> Void
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "RecentFilesManager")

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        clearAppRecentDocuments: @escaping @MainActor () -> Void = {
            NSDocumentController.shared.clearRecentDocuments(nil)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.clearAppRecentDocuments = clearAppRecentDocuments
    }

    /// Clear both the app-level and system-wide recents. Throws only if a
    /// concrete sfl removal fails for a reason other than "file vanished
    /// between listing and removal" — missing files are not an error.
    func clear() throws {
        clearAppRecentDocuments()
        try clearSharedFileListRecents()
    }

    /// On-disk source of truth for the Apple-menu Recent Items list.
    /// Skipped when the directory is missing (fresh user account), and
    /// only `com.apple.LSSharedFileList.Recent*.sfl*` files are removed —
    /// favorites / non-Recent sfl entries are not part of "recent items".
    private func clearSharedFileListRecents() throws {
        let directory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.apple.sharedfilelist", isDirectory: true)

        guard fileManager.fileExists(atPath: directory.path) else { return }

        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in entries {
            let name = url.lastPathComponent
            // Tightened glob: prefix `com.apple.LSSharedFileList.Recent`
            // *and* an `.sfl*` extension. The prefix-only check would
            // sweep up any future Apple file that happened to start with
            // "Recent" (e.g. a hypothetical `Recent.config.plist`); the
            // suffix anchors removal to the SharedFileList file format
            // we actually understand. `.sfl2` is the older format,
            // `.sfl3` the modern one — both are removed.
            let ext = url.pathExtension
            guard name.hasPrefix("com.apple.LSSharedFileList.Recent"),
                  ext == "sfl" || ext == "sfl2" || ext == "sfl3"
            else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // File vanished between listing and removal — fine.
                continue
            }
        }
    }
}
