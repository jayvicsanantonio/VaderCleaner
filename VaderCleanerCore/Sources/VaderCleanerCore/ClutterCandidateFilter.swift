// ClutterCandidateFilter.swift
// Decides which walked files may be offered as removable duplicate or similar copies, holding back hidden files and anything inside a dependency tree, build output, or version-control checkout.

import Foundation

/// Answers "may this file be offered as a redundant copy?" for the duplicate and
/// similar-image scans.
///
/// Identical bytes don't make a file redundant. Every package in `node_modules`
/// ships the same `LICENSE`, two clones of a repo are thousands of "duplicates",
/// and `.git/objects` entries match across repos, yet Trashing any of them breaks
/// the project that owns it. The walker emits all of these, because other scans
/// want them, so this is applied by the two scans that recommend removal.
///
/// Only what sits at or below a scan root counts. A home directory that is itself
/// a dotfiles repo must not hide all of `~/Documents`, and a root the user picked
/// inside a hidden folder was chosen deliberately.
///
/// Mutating because it memoizes per directory: a checkout check is a filesystem
/// probe, and candidates cluster heavily in the same folders.
struct ClutterCandidateFilter {

    /// Folder names that hold installed dependencies or build output.
    static let managedDirectoryNames: Set<String> = [
        "node_modules", "bower_components", "__pycache__", "site-packages",
        "Pods", "DerivedData", "venv",
    ]

    /// Entries that mark a folder as a version-control checkout. Checked with
    /// `fileExists` rather than as a directory because a linked git worktree's
    /// `.git` is a file.
    private static let checkoutMarkers = [".git", ".hg", ".svn"]

    private let rootPaths: Set<String>
    private var isManagedByDirectory: [String: Bool] = [:]

    init(roots: [URL]) {
        rootPaths = Set(roots.map(Self.comparablePath))
    }

    mutating func isOffered(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") { return false }
        return !isManaged(directory: Self.comparablePath(url.deletingLastPathComponent()))
    }

    private mutating func isManaged(directory path: String) -> Bool {
        if let known = isManagedByDirectory[path] { return known }
        let managed: Bool
        if rootPaths.contains(path) {
            managed = Self.isCheckout(path)
        } else if path == "/" || path.isEmpty {
            managed = false
        } else {
            let name = (path as NSString).lastPathComponent
            managed = name.hasPrefix(".")
                || Self.managedDirectoryNames.contains(name)
                || Self.isCheckout(path)
                || isManaged(directory: (path as NSString).deletingLastPathComponent)
        }
        isManagedByDirectory[path] = managed
        return managed
    }

    private static func isCheckout(_ path: String) -> Bool {
        checkoutMarkers.contains { FileManager.default.fileExists(atPath: path + "/" + $0) }
    }

    /// A file URL's path in one spelling. The walker can report a `/var/...` root
    /// as `/private/var/...`, so roots and files are compared with the firmlink
    /// prefix dropped, which still names the same place on disk.
    static func comparablePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
