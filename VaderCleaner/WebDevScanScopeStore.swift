// WebDevScanScopeStore.swift
// Observable selection of the directories the Web Development Junk project scan walks — the common code directories under home by default, or a user-chosen folder — persisted to UserDefaults.

import Foundation
import Observation

/// Holds which directories the scattered-project half of the Web Development
/// Junk scan (`DeveloperProjectScanner`) walks.
///
/// The default scope is the common code directories under the user's home
/// (`~/Developer`, `~/Projects`, … ) that actually exist, so a fresh install
/// finds projects without the user configuring anything and never walks
/// directories that aren't there. When the user picks a folder, that folder is
/// walked directly instead. The choice persists as a single absolute path so it
/// survives relaunch; `nil` means the default scope.
///
/// The scanner reads `scanRoots` per run, so a freshly-picked folder takes
/// effect on the very next scan — the same per-scan snapshot pattern the My
/// Clutter scope store uses.
@MainActor
@Observable
final class WebDevScanScopeStore {

    /// Directory names, relative to home, searched by default. Only those that
    /// exist on disk become scan roots, so the list can stay broad without
    /// forcing walks of absent folders.
    static let defaultProjectDirectoryNames = [
        "Developer",
        "Projects",
        "Code",
        "src",
        "repos",
        "dev",
        "work",
    ]

    private enum Key {
        static let folderPath = "webDevJunk.scanFolderPath"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private let fileManager: FileManager

    /// Absolute path of the user-chosen scan folder, or `nil` for the default
    /// scope (the existing common code directories under home).
    private(set) var selectedFolderPath: String?

    init(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.selectedFolderPath = defaults.string(forKey: Key.folderPath)
    }

    /// Whether the default scope is active. Drives the picker's checkmark and
    /// the scanner's choice of the common code directories.
    var isDefault: Bool { selectedFolderPath == nil }

    /// The user-chosen scan folder, or `nil` for the default scope. Drives the
    /// Settings picker's capsule and "currently picked" menu row.
    var selectedFolderURL: URL? {
        selectedFolderPath.map { URL(fileURLWithPath: $0) }
    }

    /// The directories the project scan should walk: the existing common code
    /// directories under home for the default scope, otherwise the chosen folder.
    var scanRoots: [URL] {
        if let selectedFolderPath {
            return [URL(fileURLWithPath: selectedFolderPath)]
        }
        return Self.defaultProjectDirectoryNames
            .map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0) }
    }

    /// True when this scan has nothing to look at: no folder picked, and none
    /// of the common code directories exist on this Mac.
    ///
    /// Settings uses it to hide the Web Development Junk row entirely. Someone
    /// who doesn't write code shouldn't be asked where their "project junk"
    /// lives — and the scan would find nothing either way. An explicit pick
    /// always counts, so a user who has configured this keeps the control even
    /// if the folder later disappears.
    var isDormant: Bool { isDefault && scanRoots.isEmpty }

    /// Switch back to scanning the default common code directories.
    func selectDefault() {
        guard selectedFolderPath != nil else { return }
        selectedFolderPath = nil
        defaults.removeObject(forKey: Key.folderPath)
    }

    /// Scan the chosen folder directly.
    func selectFolder(_ url: URL) {
        selectedFolderPath = url.path
        defaults.set(url.path, forKey: Key.folderPath)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
