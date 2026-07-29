// AssociatedFileFinder.swift
// Locates on-disk artifacts (preferences, caches, logs, containers, launch agents, …) that belong to a given app bundle so the App Uninstaller can review and Trash them alongside the .app bundle.

import Foundation

/// Production finder — looks under `~/Library/...` and `/Library/...`
/// for files and directories whose names match the given bundle ID.
///
/// All locations under the user's home are user-writable, so removal via
/// `NSWorkspace.recycle` succeeds without privilege escalation.
/// `/Library/LaunchAgents/*<bundleID>*.plist` is also surfaced; the
/// recycler will prompt the user for authorization when moving root-owned
/// items, which is the standard macOS Finder behavior for Trashing system
/// files.
struct DefaultAssociatedFileFinder: Sendable {

    /// See `DefaultAppDiscovery.fileManager` — `FileManager` is not `Sendable`,
    /// but `.default` is documented thread-safe and test fixtures are
    /// single-threaded, so the isolation is opted out of per property.
    nonisolated(unsafe) private let fileManager: FileManager
    private let homeDirectory: URL
    private let systemLibraryDirectory: URL
    /// Canonicalised user exclusions. Any candidate whose canonical path
    /// equals or sits beneath one of these is dropped from the result so
    /// the uninstaller never Trashes a path the user told the app to
    /// leave alone. Injected (like `homeDirectory`) so the production
    /// wiring can snapshot the live `ExclusionsStore` per uninstall.
    private let canonicalExclusions: [String]

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLibraryDirectory: URL = URL(fileURLWithPath: "/Library", isDirectory: true),
        excluding: [URL] = []
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.systemLibraryDirectory = systemLibraryDirectory
        self.canonicalExclusions = excluding.map(PathExclusionMatcher.canonicalize)
    }

    func find(forBundleID bundleID: String) async -> [AssociatedFile] {
        let fileManager = fileManager
        let userLibrary = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let systemLibrary = systemLibraryDirectory
        let canonicalExclusions = canonicalExclusions

        return await Task.detached(priority: .userInitiated) {
            var results = preferenceFiles(
                bundleID: bundleID,
                userLibrary: userLibrary,
                systemLibrary: systemLibrary,
                fileManager: fileManager
            )
            results += singleNameFiles(
                bundleID: bundleID,
                userLibrary: userLibrary,
                systemLibrary: systemLibrary,
                fileManager: fileManager
            )
            results += containerAndStateFiles(
                bundleID: bundleID,
                userLibrary: userLibrary,
                fileManager: fileManager
            )
            results += launchdFiles(
                bundleID: bundleID,
                userLibrary: userLibrary,
                systemLibrary: systemLibrary,
                fileManager: fileManager
            )
            return Self.sortedForDisplay(
                applyingExclusions(to: results, canonicalExclusions: canonicalExclusions)
            )
        }.value
    }

    /// The `~/Library` and `/Library` subdirectories that hold a single entry
    /// named exactly for the bundle ID, rather than a pattern match.
    private static let singleNameLocations: [(String, AssociatedFileCategory)] = [
        ("Application Support", .applicationSupport),
        ("Caches", .cache),
        ("Logs", .logs),
        ("Containers", .containers),
        ("HTTPStorages", .containers)
    ]

    /// Returns every entry in `directory` whose name matches the bundle ID
    /// on a dot-boundary — exactly `<bundleID>` (with optional `requiredSuffix`)
    /// or `<bundleID>.<anything>` (also subject to `requiredSuffix`). Required
    /// so a search for `com.acme.helio` doesn't sweep in `com.acme.helio2`.
    /// When `requiredSuffix` is non-nil the entry name must also end with it
    /// (case-insensitive), so a Preferences scan can be locked to `.plist`
    /// files and Saved Application State to `.savedState` directories.
    /// Missing or unreadable directories are tolerated — they're the common
    /// case (most apps don't write to most of these locations).
    private func matches(
        inDirectory directory: URL,
        nameStartsWith prefix: String,
        requiredSuffix: String? = nil,
        category: AssociatedFileCategory,
        fileManager: FileManager
    ) -> [AssociatedFile] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let dottedPrefix = prefix + "."
        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            guard name == prefix || name.hasPrefix(dottedPrefix) else { return nil }
            if let requiredSuffix,
               name.range(of: requiredSuffix, options: [.caseInsensitive, .anchored, .backwards]) == nil {
                return nil
            }
            return makeAssociatedFile(at: entry, category: category, fileManager: fileManager)
        }
    }

    /// Returns every entry whose name contains the bundle ID on a
    /// dot-boundary — required for Group Containers (`<TEAMID>.<bundleID>`)
    /// and Launch Agents (`<bundleID>.helper.plist`, `<bundleID>.updater.plist`),
    /// while still rejecting siblings like `com.acme.helio2.plist` for a
    /// search of `com.acme.helio`. The bundle ID must be surrounded by
    /// dots, or anchored at the start / end of the filename.
    /// `requiredSuffix` is enforced (case-insensitive) so LaunchAgents
    /// can be locked to `.plist` files and stray binaries / unrelated
    /// resources never enter the uninstall plan.
    private func matches(
        inDirectory directory: URL,
        nameContains needle: String,
        requiredSuffix: String? = nil,
        category: AssociatedFileCategory,
        fileManager: FileManager
    ) -> [AssociatedFile] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            guard Self.nameContainsBundleID(name, bundleID: needle) else { return nil }
            if let requiredSuffix,
               name.range(of: requiredSuffix, options: [.caseInsensitive, .anchored, .backwards]) == nil {
                return nil
            }
            return makeAssociatedFile(at: entry, category: category, fileManager: fileManager)
        }
    }

    /// True when `bundleID` appears in `name` on a dot-boundary at either
    /// end or both — `<bundleID>`, `<bundleID>.suffix`, `<prefix>.<bundleID>`,
    /// or `<prefix>.<bundleID>.suffix`. Pure substring matching would mark
    /// `com.acme.helio2.plist` as a match for `com.acme.helio`, which the
    /// recycler would then Trash unsolicited.
    static func nameContainsBundleID(_ name: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        guard let range = name.range(of: bundleID) else { return false }
        let hasLeftBoundary = range.lowerBound == name.startIndex
            || name[name.index(before: range.lowerBound)] == "."
        let hasRightBoundary = range.upperBound == name.endIndex
            || name[range.upperBound] == "."
        return hasLeftBoundary && hasRightBoundary
    }

    /// Stat + size for a candidate path. Returns `nil` when the path
    /// doesn't exist, so callers can probe a fixed list of candidates
    /// without checking existence themselves.
    private func makeAssociatedFile(
        at url: URL,
        category: AssociatedFileCategory,
        fileManager: FileManager
    ) -> AssociatedFile? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let size = pathSize(at: url, fileManager: fileManager)
        return AssociatedFile(url: url, sizeBytes: size, category: category)
    }

    /// Recursive byte size for a single path. Directories sum their
    /// regular-file children; regular files return their own size.
    private func pathSize(at url: URL, fileManager: FileManager) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                return size.int64Value
            }
            return 0
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let fileSize = values?.fileSize {
                total += Int64(fileSize)
            }
        }
        return total
    }

    /// Stable category sort key — declaration order in `allCases`.
    private static func categoryOrder(_ category: AssociatedFileCategory) -> Int {
        AssociatedFileCategory.allCases.firstIndex(of: category) ?? Int.max
    }

    /// Stable order: category (in declaration order), then URL path —
    /// makes the rendered list deterministic across runs and makes
    /// test fixtures easier to reason about.
    private static func sortedForDisplay(_ files: [AssociatedFile]) -> [AssociatedFile] {
        files.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return categoryOrder(lhs.category) < categoryOrder(rhs.category)
            }
            return lhs.url.path < rhs.url.path
        }
    }

    // MARK: - Per-location lookups
    //
    // One method per family of on-disk locations, each returning its own
    // candidates so `find(forBundleID:)` reads as the list of places checked.

        /// Preference plists, user and system domain.
    ///
    /// Three valid spellings on disk:
    ///   ~/Library/Preferences/<bundleID>.plist
    ///   ~/Library/Preferences/<bundleID>.*.plist (per-host LSSharedFileList variants)
    ///   ~/Library/Preferences/ByHost/<bundleID>.*.plist
    private func preferenceFiles(
        bundleID: String,
        userLibrary: URL,
        systemLibrary: URL,
        fileManager: FileManager
    ) -> [AssociatedFile] {
        let preferencesDir = userLibrary.appendingPathComponent("Preferences", isDirectory: true)
        let byHostDir = preferencesDir.appendingPathComponent("ByHost", isDirectory: true)
        // Installers that drop machine-wide data (typically through pkg
        // installers) leave their residue under `/Library/...`, not the user's
        // home. These paths are usually root-owned; the recycler prompts for
        // authorization the same way Finder does when Trashing system files.
        let systemPreferencesDir = systemLibrary.appendingPathComponent("Preferences", isDirectory: true)

        return [preferencesDir, byHostDir, systemPreferencesDir].flatMap { directory in
            matches(
                inDirectory: directory,
                nameStartsWith: bundleID,
                requiredSuffix: ".plist",
                category: .preferences,
                fileManager: fileManager
            )
        }
    }

    /// The fixed subdirectories that hold a single entry named for the bundle ID,
    /// checked under both `~/Library` and `/Library`. Without the system-domain
    /// half, uninstalling would leave machine-wide caches / app support orphaned.
    private func singleNameFiles(
        bundleID: String,
        userLibrary: URL,
        systemLibrary: URL,
        fileManager: FileManager
    ) -> [AssociatedFile] {
        [userLibrary, systemLibrary].flatMap { root in
            Self.singleNameLocations.compactMap { subpath, category in
                let candidate = root
                    .appendingPathComponent(subpath, isDirectory: true)
                    .appendingPathComponent(bundleID, isDirectory: false)
                return makeAssociatedFile(at: candidate, category: category, fileManager: fileManager)
            }
        }
    }

    /// Group containers and saved application state, both user-domain.
    private func containerAndStateFiles(
        bundleID: String,
        userLibrary: URL,
        fileManager: FileManager
    ) -> [AssociatedFile] {
        // Vendors prefix the group-container directory with a Team ID:
        //   ~/Library/Group Containers/<TEAMID>.<bundleID>
        // so a "contains bundleID" match is required.
        let groupContainers = matches(
            inDirectory: userLibrary.appendingPathComponent("Group Containers", isDirectory: true),
            nameContains: bundleID,
            category: .groupContainers,
            fileManager: fileManager
        )

        //   ~/Library/Saved Application State/<bundleID>.savedState
        let savedState = matches(
            inDirectory: userLibrary.appendingPathComponent("Saved Application State", isDirectory: true),
            nameStartsWith: bundleID,
            requiredSuffix: ".savedState",
            category: .savedState,
            fileManager: fileManager
        )

        return groupContainers + savedState
    }

    /// Launch agents (user and system domain) and launch daemons.
    private func launchdFiles(
        bundleID: String,
        userLibrary: URL,
        systemLibrary: URL,
        fileManager: FileManager
    ) -> [AssociatedFile] {
        // User-domain (no privilege required) and system-domain (recycle will
        // prompt for authorization). Match a contains pattern because vendors
        // sometimes append " .plist" or ".plist.helper" suffixes to the bundle ID.
        let agents = [
            userLibrary.appendingPathComponent("LaunchAgents", isDirectory: true),
            systemLibrary.appendingPathComponent("LaunchAgents", isDirectory: true)
        ].flatMap { directory in
            matches(
                inDirectory: directory,
                nameContains: bundleID,
                requiredSuffix: ".plist",
                category: .launchAgents,
                fileManager: fileManager
            )
        }

        // Apps that install a privileged helper register it under
        // `/Library/LaunchDaemons/<bundleID>*.plist`. Without this lookup the
        // daemon stays registered after uninstall and can keep running on the
        // next boot. The recycler prompts for authorization since the directory
        // is root-owned.
        let daemons = matches(
            inDirectory: systemLibrary.appendingPathComponent("LaunchDaemons", isDirectory: true),
            nameContains: bundleID,
            requiredSuffix: ".plist",
            category: .launchDaemons,
            fileManager: fileManager
        )

        return agents + daemons
    }

    /// Drops anything the user excluded. The candidate count here is small (a
    /// handful of fixed locations per bundle ID), so the per-path symlink
    /// resolution `canonicalize` does is cheap — unlike the bulk scanners, which
    /// project through a root mapper to avoid a syscall per enumerated file.
    ///
    /// A candidate is dropped when it is itself excluded *or* when an excluded
    /// path lives inside it. The uninstaller recycles each candidate as one unit,
    /// so emitting a parent directory that contains an excluded descendant would
    /// Trash the excluded subtree along with it. Erring toward "leave the parent
    /// alone" is the safe choice — it never deletes data the user told us to keep.
    private func applyingExclusions(
        to files: [AssociatedFile],
        canonicalExclusions: [String]
    ) -> [AssociatedFile] {
        guard !canonicalExclusions.isEmpty else { return files }
        return files.filter { file in
            let canonicalPath = PathExclusionMatcher.canonicalize(file.url)
            let excluded = PathExclusionMatcher.isExcluded(
                path: canonicalPath,
                by: canonicalExclusions
            ) || PathExclusionMatcher.containsExcludedDescendant(
                of: canonicalPath,
                in: canonicalExclusions
            )
            return !excluded
        }
    }
}
