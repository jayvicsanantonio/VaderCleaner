// UserFilesPathProviding.swift
// Resolves the home-directory subtrees the Large & Old Files scanner walks, plus the TCC-protected media stores (Photos / Apple Music) it must skip so the scan never trips a macOS privacy prompt.

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

    /// TCC-protected media stores that sit under `roots()` and must be folded
    /// into the scan's exclusion list. Descending into a Photos library bundle
    /// or the Apple Music media folder triggers a macOS privacy prompt for
    /// Photos or Music access — skipping them outright keeps the Large & Old
    /// Files scan silent (and avoids ever offering the user's photo library
    /// up as a deletable "large file").
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

    /// Discovers the TCC-protected media stores under the user's home.
    ///
    /// Photo libraries are found by walking `~/Pictures` recursively: a user
    /// can rename the default library, keep several, or tuck one inside a
    /// subfolder, so a shallow listing of fixed names would miss them. The
    /// walk never descends *into* a bundle — that is what trips the Photos
    /// prompt — because `.skipsPackageDescendants` skips `.photoslibrary`
    /// packages and `Photo Booth Library` is skipped explicitly. Extension
    /// and name matching is case-insensitive to mirror the default
    /// case-insensitive APFS volume (and `FileScanner`'s exclusion matching).
    ///
    /// The Apple Music and legacy iTunes media folders sit at the fixed paths
    /// `~/Music/Music` and `~/Music/iTunes`; they are returned only when they
    /// actually exist so the exclusion list never carries phantom paths.
    func protectedMediaStores() -> [URL] {
        let fileManager = FileManager.default
        var stores: [URL] = []

        let pictures = homeDirectory.appendingPathComponent("Pictures", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: pictures,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                if url.pathExtension.caseInsensitiveCompare("photoslibrary") == .orderedSame {
                    stores.append(url)
                } else if url.lastPathComponent.caseInsensitiveCompare("Photo Booth Library") == .orderedSame {
                    stores.append(url)
                    // Photo Booth's library is not a registered package type,
                    // so `.skipsPackageDescendants` would not stop the walk
                    // from descending into it — skip its contents explicitly.
                    enumerator.skipDescendants()
                }
            }
        }

        let music = homeDirectory.appendingPathComponent("Music", isDirectory: true)
        for mediaFolder in ["Music", "iTunes"] {
            let url = music.appendingPathComponent(mediaFolder, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                stores.append(url)
            }
        }

        return stores
    }
}
