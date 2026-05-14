// AssociatedFileFinder.swift
// Locates on-disk artifacts (preferences, caches, logs, containers, launch agents, …) that belong to a given app bundle so the App Uninstaller can review and Trash them alongside the .app bundle.

import Foundation
import os.log

/// Test seam between `AppUninstallerViewModel` and the on-disk associated-
/// file lookup. The protocol is async so production implementations can hop
/// to a background actor for the directory traversal without blocking the
/// view-model's main-actor isolation.
protocol AssociatedFileFinding: Sendable {
    func find(forBundleID bundleID: String) async -> [AssociatedFile]
}

/// Production finder — looks under `~/Library/...` and `/Library/...`
/// for files and directories whose names match the given bundle ID.
///
/// All locations under the user's home are user-writable, so removal via
/// `NSWorkspace.recycle` succeeds without privilege escalation.
/// `/Library/LaunchAgents/*<bundleID>*.plist` is also surfaced; the
/// recycler will prompt the user for authorization when moving root-owned
/// items, which is the standard macOS Finder behavior for Trashing system
/// files.
struct DefaultAssociatedFileFinder: AssociatedFileFinding, Sendable {

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let systemLibraryDirectory: URL
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "AssociatedFileFinder")

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLibraryDirectory: URL = URL(fileURLWithPath: "/Library", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.systemLibraryDirectory = systemLibraryDirectory
    }

    func find(forBundleID bundleID: String) async -> [AssociatedFile] {
        let fileManager = fileManager
        let userLibrary = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let systemLibrary = systemLibraryDirectory

        return await Task.detached(priority: .userInitiated) {
            var results: [AssociatedFile] = []

            // ── Preferences ─────────────────────────────────────────
            // Three valid spellings on disk:
            //   ~/Library/Preferences/<bundleID>.plist
            //   ~/Library/Preferences/<bundleID>.*.plist (per-host LSSharedFileList variants)
            //   ~/Library/Preferences/ByHost/<bundleID>.*.plist
            let preferencesDir = userLibrary.appendingPathComponent("Preferences", isDirectory: true)
            results.append(contentsOf: matches(
                inDirectory: preferencesDir,
                nameStartsWith: bundleID,
                requiredSuffix: ".plist",
                category: .preferences,
                fileManager: fileManager
            ))
            let byHostDir = preferencesDir.appendingPathComponent("ByHost", isDirectory: true)
            results.append(contentsOf: matches(
                inDirectory: byHostDir,
                nameStartsWith: bundleID,
                requiredSuffix: ".plist",
                category: .preferences,
                fileManager: fileManager
            ))

            // ── Single-name lookups under ~/Library ─────────────────
            let singleNameLocations: [(String, AssociatedFileCategory)] = [
                ("Application Support", .applicationSupport),
                ("Caches", .cache),
                ("Logs", .logs),
                ("Containers", .containers),
                ("HTTPStorages", .containers)
            ]
            for (subpath, category) in singleNameLocations {
                let candidate = userLibrary
                    .appendingPathComponent(subpath, isDirectory: true)
                    .appendingPathComponent(bundleID, isDirectory: false)
                if let file = makeAssociatedFile(at: candidate, category: category, fileManager: fileManager) {
                    results.append(file)
                }
            }

            // ── Group Containers ────────────────────────────────────
            // Vendors prefix the directory with a Team ID:
            //   ~/Library/Group Containers/<TEAMID>.<bundleID>
            // so a "contains bundleID" match is required.
            let groupContainersDir = userLibrary
                .appendingPathComponent("Group Containers", isDirectory: true)
            results.append(contentsOf: matches(
                inDirectory: groupContainersDir,
                nameContains: bundleID,
                category: .groupContainers,
                fileManager: fileManager
            ))

            // ── Saved Application State ─────────────────────────────
            //   ~/Library/Saved Application State/<bundleID>.savedState
            let savedStateDir = userLibrary
                .appendingPathComponent("Saved Application State", isDirectory: true)
            results.append(contentsOf: matches(
                inDirectory: savedStateDir,
                nameStartsWith: bundleID,
                requiredSuffix: ".savedState",
                category: .savedState,
                fileManager: fileManager
            ))

            // ── Launch Agents ───────────────────────────────────────
            // User-domain (no privilege required) and system-domain
            // (recycle will prompt for authorization). Match a contains
            // pattern because vendors sometimes append " .plist" or
            // ".plist.helper" suffixes to the bundle ID.
            let userLaunchAgentsDir = userLibrary
                .appendingPathComponent("LaunchAgents", isDirectory: true)
            results.append(contentsOf: matches(
                inDirectory: userLaunchAgentsDir,
                nameContains: bundleID,
                requiredSuffix: ".plist",
                category: .launchAgents,
                fileManager: fileManager
            ))
            let systemLaunchAgentsDir = systemLibrary
                .appendingPathComponent("LaunchAgents", isDirectory: true)
            results.append(contentsOf: matches(
                inDirectory: systemLaunchAgentsDir,
                nameContains: bundleID,
                requiredSuffix: ".plist",
                category: .launchAgents,
                fileManager: fileManager
            ))

            // Stable order: category (in declaration order), then URL path —
            // makes the rendered list deterministic across runs and makes
            // test fixtures easier to reason about.
            results.sort { lhs, rhs in
                if lhs.category != rhs.category {
                    return Self.categoryOrder(lhs.category) < Self.categoryOrder(rhs.category)
                }
                return lhs.url.path < rhs.url.path
            }
            return results
        }.value
    }

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
}
