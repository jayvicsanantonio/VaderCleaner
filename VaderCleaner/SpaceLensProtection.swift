// SpaceLensProtection.swift
// Decides which Space Lens items are protected from removal — the boot volume's system locations and the user's own managed home folders — and the display category shown in the list badge and hover card.

import Foundation

/// Classifies a scanned location as protected (not selectable for removal) and
/// supplies the human-readable category Space Lens shows in the row badge and
/// the hover card.
///
/// Protection mirrors what a careful cleaner blocks: the system roots that make
/// the OS work (`/System`, `/Library`, …), the user's home directory itself, and
/// the standard macOS home folders the system manages (`~/Library`,
/// `~/Documents`, …). Everything else — a custom `~/Videos`, a `~/Developer`
/// tree, another account under `/Users` — stays selectable.
enum SpaceLensProtection {

    /// The category shown beside a row / in the hover card.
    enum Category: Equatable {
        case systemFolder
        case homeFolder
        case folder
        case file

        /// Display string, matching the reference UI ("System folder").
        var displayName: String {
            switch self {
            case .systemFolder: return String(localized: "System folder")
            case .homeFolder:   return String(localized: "Home folder")
            case .folder:       return String(localized: "Folder")
            case .file:         return String(localized: "File")
            }
        }
    }

    /// Absolute boot-volume roots that are never user-removable — the path
    /// itself and everything beneath it.
    private static let systemRoots: [String] = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/private",
        "/cores", "/opt", "/etc", "/var", "/Applications", "/Network",
        "/Users/Shared"
    ]

    /// Paths protected only as an exact match, not their descendants — `/Users`
    /// itself is a system container (shown with an "i" badge), but the accounts
    /// inside it (other than the current home) stay removable.
    private static let exactSystemPaths: Set<String> = ["/Users"]

    /// Standard macOS home folders the system manages; protected even though
    /// they live under the user's home. A folder the user created themselves
    /// (e.g. "Videos", "Developer") is not in this set, so it stays removable.
    private static let managedHomeFolders: Set<String> = [
        "Library", "Documents", "Desktop", "Downloads",
        "Movies", "Music", "Pictures", "Public", "Sites", "Applications"
    ]

    /// `true` when the location must not be offered for removal.
    static func isProtected(
        url: URL,
        isDirectory: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        switch category(url: url, isDirectory: isDirectory, homeDirectory: homeDirectory) {
        case .systemFolder, .homeFolder: return true
        case .folder, .file:             return false
        }
    }

    /// The display category for a location.
    static func category(
        url: URL,
        isDirectory: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Category {
        let path = url.standardizedFileURL.path
        let home = homeDirectory.standardizedFileURL.path

        if path == home { return .homeFolder }
        if isSystem(path: path) { return .systemFolder }
        if isManagedHomeFolder(path: path, home: home) { return .systemFolder }
        return isDirectory ? .folder : .file
    }

    /// Path is the volume root, a system root (or inside one), or an
    /// exact-match system container like `/Users`.
    private static func isSystem(path: String) -> Bool {
        if path == "/" { return true }
        if exactSystemPaths.contains(path) { return true }
        return systemRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Path is a direct standard home folder, e.g. `<home>/Library`.
    private static func isManagedHomeFolder(path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let relative = String(path.dropFirst(home.count + 1))
        // Only the top-level folder is protected, not its contents.
        guard !relative.contains("/") else { return false }
        return managedHomeFolders.contains(relative)
    }
}
