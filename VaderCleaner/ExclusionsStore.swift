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

    /// Adds `path` to the exclusion list. Silently ignored if `path` is already
    /// present — duplicates would only confuse the UI and waste scanner cycles.
    func add(path: String) {
        guard !exclusions.contains(path) else { return }
        exclusions.append(path)
        persist()
    }

    /// Removes the first occurrence of `path`. No-op if the path is not in the
    /// list, so callers don't need to guard.
    func remove(path: String) {
        guard exclusions.contains(path) else { return }
        exclusions.removeAll { $0 == path }
        persist()
    }

    private func persist() {
        defaults.set(exclusions, forKey: Key.exclusions)
    }
}
