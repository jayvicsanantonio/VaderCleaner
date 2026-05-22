// UserFilesPathProviding.swift
// Resolves the home-directory subtrees the Large & Old Files scanner walks, plus the fixed-path Apple Music media folders it excludes by path so the scan never trips a macOS privacy prompt.

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

    /// The fixed-path TCC-protected media folders under `roots()` that must be
    /// folded into the scan's exclusion list — the Apple Music media folder and
    /// the legacy iTunes folder. These are plainly-named directories, so they
    /// cannot be recognised by name mid-walk and must be excluded by path.
    /// Photo-library bundles, which can live anywhere under any root, are
    /// skipped in-walk by `FileScanner` (see
    /// `FileScanOptions.skipsProtectedMediaStores`) rather than listed here.
    func protectedMediaStores() -> [URL]
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

    /// Returns the fixed-path Apple Music media folder (`~/Music/Music`) and the
    /// legacy iTunes folder (`~/Music/iTunes`) when they exist.
    ///
    /// These are plainly-named directories at known paths, so unlike
    /// photo-library bundles they cannot be recognised by name during the walk
    /// and must be excluded by path. They are returned only when they actually
    /// exist so the exclusion list never carries phantom paths.
    ///
    /// Photo-library bundles are deliberately *not* listed here — they can live
    /// at any depth under any scanned root, so `FileScanner` detects and skips
    /// them in-walk via `FileScanOptions.skipsProtectedMediaStores`.
    func protectedMediaStores() -> [URL] {
        let fileManager = FileManager.default
        let music = homeDirectory.appendingPathComponent("Music", isDirectory: true)
        return ["Music", "iTunes"].compactMap { mediaFolder in
            let url = music.appendingPathComponent(mediaFolder, isDirectory: true)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
    }
}
