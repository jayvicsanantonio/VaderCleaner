// ExclusionEntry.swift
// Presentation model for one Ignore List row — readable name, abbreviated location, and whether the path still exists.

import Foundation

/// One row in the Ignore List.
///
/// The store keeps absolute paths, which are accurate but hard to read at a
/// glance — `/Users/someone/Developer` buries the one word the user recognises.
/// This splits the path into a name and a location, and records whether the
/// path still exists so entries left behind by a deleted or renamed folder can
/// be shown as the dead weight they are rather than looking active.
struct ExclusionEntry: Identifiable, Hashable {

    /// The stored absolute path — the row's identity, so selection survives the
    /// list being rebuilt after an existence refresh.
    let path: String
    /// The item's own name, shown as the row's headline.
    let name: String
    /// The containing folder, with home abbreviated to `~`.
    let location: String
    /// Whether the path is still present on disk.
    let exists: Bool

    var id: String { path }

    /// Builds rows for `paths`, preserving order — the store's insertion order
    /// is what puts newly added entries at the end of the list.
    ///
    /// `exists` is injected so the mapping is testable without touching disk;
    /// production passes `FileManager.default.fileExists(atPath:)`.
    static func entries(
        for paths: [String],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [ExclusionEntry] {
        paths.map { path in
            let url = URL(fileURLWithPath: path)
            return ExclusionEntry(
                path: path,
                name: url.lastPathComponent,
                location: abbreviate(url.deletingLastPathComponent().path, home: homeDirectory),
                exists: exists(path)
            )
        }
    }

    /// Replaces the home directory prefix with `~`. Matching is done at a path
    /// component boundary so `/Users/someoneelse` isn't mistaken for a path
    /// inside `/Users/someone`.
    private static func abbreviate(_ path: String, home: String) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == trimmedHome { return "~" }
        guard path.hasPrefix(trimmedHome + "/") else { return path }
        return "~" + path.dropFirst(trimmedHome.count)
    }
}
