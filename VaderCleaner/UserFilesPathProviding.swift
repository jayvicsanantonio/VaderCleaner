// UserFilesPathProviding.swift
// Resolves the home-directory subtrees that the Large & Old Files scanner walks, returned as plain root URLs (no category tag — the scanner classifies per-file by size/age).

import Foundation

/// Test seam between `LargeOldFilesScanner` and the real macOS home layout.
/// Implementations return the concrete `[URL]` to feed into a scan. Tests
/// inject a stub returning paths under a temp directory, which is why the
/// production `DefaultUserFilesPathProvider` lives behind the same protocol
/// instead of being a free function on the scanner.
///
/// Distinct from `SystemPathProviding` — that one carries a `ScanCategory`
/// per root because the System Junk feature decides "this is junk because of
/// where it lives". Large & Old files are classified by content (size, last
/// access date), so the root list is pure URLs and the scanner does the
/// per-file tagging.
protocol UserFilesPathProviding {
    func roots() -> [URL]
}

/// Production implementation that returns the canonical user directories that
/// might contain large or stale files: `~/Documents`, `~/Downloads`,
/// `~/Desktop`, `~/Movies`, `~/Music`, `~/Pictures`, and `~/Library`.
///
/// `~/Library` is intentionally included — it can hold multi-gigabyte caches
/// or `Application Support` blobs left behind by uninstalled apps that the
/// System Junk path provider doesn't touch. The user-confirmation alert in
/// `LargeOldFilesView` mitigates accidental deletion of live app data.
struct DefaultUserFilesPathProvider: UserFilesPathProviding {

    private let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func roots() -> [URL] {
        ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures", "Library"]
            .map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
    }
}
