// MyClutterScanScopeStore.swift
// Observable selection of the folder the My Clutter scan walks — the canonical home subtrees by default, or a user-chosen directory — persisted to UserDefaults.

import Foundation
import Observation

/// Holds which folder the My Clutter (large & old files) scan should walk.
///
/// The default scope is "home": the scanner walks the canonical home subtrees
/// (`~/Documents`, `~/Downloads`, … `~/Library`) exactly as it always has. When
/// the user picks a folder, that folder is walked directly instead. The choice
/// is persisted as a single absolute path so it survives relaunch; `nil` means
/// the default home scope.
///
/// The scanner reads `scanRoots` per run, so a freshly-picked folder takes
/// effect on the very next scan — the same per-scan snapshot pattern the
/// exclusions store uses.
@MainActor
@Observable
final class MyClutterScanScopeStore {

    private enum Key {
        static let folderPath = "myClutter.scanFolderPath"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let homeDirectory: URL

    /// Absolute path of the user-chosen scan folder, or `nil` for the default
    /// home scope (the canonical home subtrees the scanner walks).
    private(set) var selectedFolderPath: String?

    init(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        let stored = defaults.string(forKey: Key.folderPath)
        // A stored path equal to the home directory collapses back to the home
        // scope so the picker shows the home checkmark rather than a redundant
        // explicit-folder selection.
        if let stored, stored == homeDirectory.path {
            self.selectedFolderPath = nil
        } else {
            self.selectedFolderPath = stored
        }
    }

    /// Whether the default home scope is active. Drives the picker's checkmark
    /// and the scanner's choice of the canonical subtrees.
    var isHome: Bool { selectedFolderPath == nil }

    /// The folder the user is scanning: the home directory for the default
    /// scope, otherwise the chosen folder.
    var selectedURL: URL {
        guard let selectedFolderPath else { return homeDirectory }
        return URL(fileURLWithPath: selectedFolderPath)
    }

    /// The folder name shown in the picker capsule — the selected folder's last
    /// path component (e.g. the user's short name for the home directory).
    var displayName: String { selectedURL.lastPathComponent }

    /// Roots the scanner should walk: `nil` means "the canonical home subtrees",
    /// which `DefaultUserFilesPathProvider` expands itself; a chosen folder is
    /// walked directly as a single root.
    var scanRoots: [URL]? {
        guard let selectedFolderPath else { return nil }
        return [URL(fileURLWithPath: selectedFolderPath)]
    }

    /// Switch back to scanning the canonical home subtrees.
    func selectHome() {
        guard selectedFolderPath != nil else { return }
        selectedFolderPath = nil
        defaults.removeObject(forKey: Key.folderPath)
    }

    /// Scan the chosen folder directly. Picking the home directory collapses to
    /// the home scope so the two selections never diverge.
    func selectFolder(_ url: URL) {
        if url.path == homeDirectory.path {
            selectHome()
            return
        }
        selectedFolderPath = url.path
        defaults.set(url.path, forKey: Key.folderPath)
    }
}
