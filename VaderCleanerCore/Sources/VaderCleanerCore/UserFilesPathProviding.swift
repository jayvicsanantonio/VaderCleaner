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
/// `~/Desktop`, `~/Movies`, `~/Music`, and `~/Pictures`.
///
/// `~/Library` is intentionally left out. It holds live app data — message and
/// mail databases, keychains, containers — that no size or age rule can tell
/// from clutter, and a file there that goes unread for months may still be vital.
/// Caches are System Junk's domain and uninstalled apps' remains are the
/// Applications section's. A user who picks a folder inside it still gets that
/// folder walked.
struct DefaultUserFilesPathProvider: UserFilesPathProviding {

    private let homeDirectory: URL

    /// When the user picks a specific folder in the My Clutter intro, that
    /// folder is walked directly as the only root. `nil` keeps the default
    /// behaviour of expanding the canonical home subtrees below.
    private let explicitRoots: [URL]?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        roots: [URL]? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.explicitRoots = roots
    }

    func roots() -> [URL] {
        if let explicitRoots { return explicitRoots }
        return ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures"]
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
