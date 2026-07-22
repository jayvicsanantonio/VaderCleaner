// AppLeftoverScanner.swift
// Walks the standard ~/Library support roots and flags reverse-DNS bundle-ID entries that belong to no installed app — the orphaned files an uninstalled app left behind.

import Foundation
import os.log

/// Production scanner — lists the immediate contents of the standard support
/// roots, derives a candidate bundle ID per entry (each root names its entries
/// differently), and keeps the ones that belong to no installed app.
///
/// This is the highest-risk scanner in the section, so the matching is
/// deliberately conservative and biased toward false negatives:
///   - only entries whose name is a well-formed reverse-DNS bundle ID
///     (≥3 dot-separated alphanumeric/hyphen components) are ever considered —
///     human-named folders like "Google" are ignored;
///   - Apple (`com.apple.*`) and app-group (`group.*`) IDs are never flagged;
///   - an entry is treated as belonging to an installed app if its ID matches
///     an installed bundle ID *or* is a sub-ID of one (e.g. a helper/XPC
///     service `com.acme.App.Helper` under installed `com.acme.App`).
/// Removal stays opt-in and routes to the Trash (restorable).
struct DefaultAppLeftoverScanner: Sendable {

    /// How a root names its entries, which determines how a bundle ID is
    /// derived from each one.
    enum RootKind {
        /// `~/Library/Preferences`: files named `<bundleID>.plist`.
        case preferences
        /// `~/Library/Caches`, `Application Support`, `Logs`: entries named
        /// exactly `<bundleID>`.
        case bundleNamedEntry
        /// `~/Library/Saved Application State`: entries named
        /// `<bundleID>.savedState`.
        case savedState
    }

    private let roots: [(url: URL, kind: RootKind)]
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "AppLeftoverScanner")

    init(
        roots: [(url: URL, kind: RootKind)] = DefaultAppLeftoverScanner.defaultRoots(),
        fileManager: FileManager = .default
    ) {
        self.roots = roots
        self.fileManager = fileManager
    }

    static func defaultRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(url: URL, kind: RootKind)] {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        return [
            (library.appendingPathComponent("Application Support", isDirectory: true), .bundleNamedEntry),
            (library.appendingPathComponent("Caches", isDirectory: true), .bundleNamedEntry),
            (library.appendingPathComponent("Preferences", isDirectory: true), .preferences),
            (library.appendingPathComponent("Logs", isDirectory: true), .bundleNamedEntry),
            (library.appendingPathComponent("Saved Application State", isDirectory: true), .savedState),
        ]
    }

    /// - Parameter excluding: paths from the user's Ignore List. Leftover files
    ///   at or beneath one are dropped, and a group left with no files at all
    ///   disappears rather than being reported as an empty finding.
    func scan(
        installedBundleIDs: Set<String>,
        excluding exclusions: [URL] = []
    ) async -> [LeftoverGroup] {
        let roots = roots
        let fileManager = fileManager
        let log = log
        let excludedPaths = exclusions.map(PathExclusionMatcher.canonicalize)
        return await Task.detached(priority: .userInitiated) {
            // Aggregate every matching URL under its bundle ID, preserving a
            // stable discovery order per root.
            var urlsByBundleID: [String: [URL]] = [:]
            var order: [String] = []

            for root in roots {
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: root.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for entry in entries {
                    guard let bundleID = Self.candidateBundleID(for: entry, kind: root.kind) else {
                        continue
                    }
                    guard !PathExclusionMatcher.isExcluded(
                        path: PathExclusionMatcher.canonicalize(entry),
                        by: excludedPaths
                    ) else { continue }
                    guard Self.looksLikeBundleID(bundleID),
                          !Self.isSystemBundleID(bundleID),
                          !Self.isCoveredByInstalled(bundleID, installed: installedBundleIDs) else {
                        continue
                    }
                    if urlsByBundleID[bundleID] == nil { order.append(bundleID) }
                    urlsByBundleID[bundleID, default: []].append(entry)
                }
            }

            let groups: [LeftoverGroup] = order.map { bundleID in
                let urls = urlsByBundleID[bundleID] ?? []
                let total = urls.reduce(Int64(0)) { $0 + Self.size(at: $1, fileManager: fileManager) }
                return LeftoverGroup(
                    bundleID: bundleID,
                    displayName: bundleID.components(separatedBy: ".").last ?? bundleID,
                    urls: urls,
                    totalBytes: total
                )
            }
            // Largest first.
            .sorted { $0.totalBytes > $1.totalBytes }

            log.debug("Leftover scan flagged \(groups.count, privacy: .public) orphaned bundle(s)")
            return groups
        }.value
    }

    // MARK: - Pure matching helpers

    /// Derives the candidate bundle ID from an entry, given its root's naming
    /// convention. Returns `nil` when the entry doesn't fit the convention.
    static func candidateBundleID(for url: URL, kind: RootKind) -> String? {
        let name = url.lastPathComponent
        switch kind {
        case .preferences:
            guard url.pathExtension.caseInsensitiveCompare("plist") == .orderedSame else { return nil }
            // `com.acme.App.plist` → `com.acme.App`.
            return url.deletingPathExtension().lastPathComponent
        case .bundleNamedEntry:
            return name
        case .savedState:
            let suffix = ".savedState"
            guard name.hasSuffix(suffix) else { return nil }
            return String(name.dropLast(suffix.count))
        }
    }

    /// Whether a string is a well-formed reverse-DNS bundle ID: at least three
    /// dot-separated components, each a non-empty run of alphanumerics or
    /// hyphens. Anything looser (human-named folders, two-component names) is
    /// rejected so the scanner never offers an ambiguous entry for removal.
    static func looksLikeBundleID(_ string: String) -> Bool {
        let components = string.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        for component in components {
            guard !component.isEmpty else { return false }
            guard CharacterSet(charactersIn: String(component)).isSubset(of: allowed) else { return false }
        }
        return true
    }

    /// Apple-owned and app-group IDs are never treated as leftovers — their
    /// support files are managed by macOS, not us.
    static func isSystemBundleID(_ string: String) -> Bool {
        string.hasPrefix("com.apple.") || string.hasPrefix("group.")
    }

    /// Whether the candidate belongs to an installed app — either an exact
    /// match, or a sub-ID of an installed app (a helper/XPC service like
    /// `com.acme.App.Helper` under installed `com.acme.App`).
    static func isCoveredByInstalled(_ candidate: String, installed: Set<String>) -> Bool {
        if installed.contains(candidate) { return true }
        return installed.contains { candidate.hasPrefix($0 + ".") }
    }

    // MARK: - Sizing

    /// Recursive byte size of a file or directory tree. Errors inside the walk
    /// are tolerated so a single unreadable child never zeros a group.
    static func size(at url: URL, fileManager: FileManager) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
