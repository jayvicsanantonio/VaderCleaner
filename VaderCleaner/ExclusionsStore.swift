// ExclusionsStore.swift
// Observable list of paths excluded from scanning — backed by UserDefaults, dedupes on add.

import Foundation
import Combine

/// Holds the user's list of absolute paths that scanners must skip. Persisted as a
/// single `[String]` value in `UserDefaults` so the list survives relaunch.
///
/// `add(path:)` is a no-op when the path is already present so the same path
/// can never appear twice in the UI. Future prompts (notably Prompt 26) will
/// inject this store into every scanner so exclusions take effect everywhere.
@MainActor
final class ExclusionsStore: ObservableObject {

    private enum Key {
        static let exclusions = "exclusions.paths"
    }

    /// Current list of excluded absolute paths. Order is insertion order — the
    /// UI relies on this so adds appear at the end of the list.
    @Published private(set) var exclusions: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.exclusions = (defaults.array(forKey: Key.exclusions) as? [String]) ?? []
    }

    /// Adds `path` to the exclusion list. The path is resolved to its canonical
    /// form first (symlinks expanded, `..`/`.` collapsed) and compared
    /// case-insensitively, since macOS's default file system is case-insensitive
    /// and `/tmp` is a symlink to `/private/tmp`. Without this step a user
    /// could appear to add the "same" path twice, and scanners that walk
    /// resolved paths would never match the stored entry.
    func add(path: String) {
        let canonical = Self.canonicalize(path)
        guard !exclusions.contains(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) else {
            return
        }
        exclusions.append(canonical)
        persist()
    }

    /// Removes the first occurrence of `path` (resolved + case-insensitive
    /// match, mirroring `add(path:)`). No-op if no entry matches, so callers
    /// don't need to guard.
    func remove(path: String) {
        let canonical = Self.canonicalize(path)
        let countBefore = exclusions.count
        exclusions.removeAll { $0.caseInsensitiveCompare(canonical) == .orderedSame }
        if exclusions.count != countBefore {
            persist()
        }
    }

    /// Resolves symlinks and standardizes the supplied path. For paths that do
    /// not exist on disk this falls back to the input string with `..`/`.`
    /// resolved — sufficient for tests and for users excluding paths under
    /// directories that may be created later.
    private static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func persist() {
        defaults.set(exclusions, forKey: Key.exclusions)
    }
}
