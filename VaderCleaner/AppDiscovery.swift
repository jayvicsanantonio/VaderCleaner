// AppDiscovery.swift
// Locates installed .app bundles under /Applications, /Applications/Utilities, and ~/Applications and returns their parsed metadata for the App Uninstaller list.

import Foundation
import os.log

/// Test seam between `AppUninstallerViewModel` and the real macOS
/// application directories. The protocol returns ready-to-display
/// `AppInfo` records so the view-model never has to walk the filesystem
/// directly — every call site can be exercised with an in-memory stub
/// in tests.
protocol AppDiscovering: Sendable {
    /// - Parameter includingSystemApps: when `false`, bundles whose
    ///   `CFBundleIdentifier` begins with `com.apple.` are filtered out.
    ///   Defaults to `false` at the view-model layer; the Preferences
    ///   toggle (future work) can flip it on.
    func installedApps(includingSystemApps: Bool) async throws -> [AppInfo]

    /// Recursive byte size of the `.app` directory tree. Runs lazily
    /// when the user selects a row in the App Uninstaller — folding
    /// this into `installedApps` would pin launch on multi-second
    /// directory walks for users with many installed apps.
    func bundleSize(at url: URL) async -> Int64
}

/// Production discovery — walks the three canonical macOS app roots and
/// reads `Info.plist` for each `.app` bundle it finds.
struct DefaultAppDiscovery: AppDiscovering, Sendable {

    private let fileManager: FileManager
    private let roots: [URL]
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "AppDiscovery")

    /// - Parameter homeDirectory: the user's home, used to resolve
    ///   `~/Applications`. Defaults to the real home; tests inject a
    ///   temp dir so the fixture is fully hermetic.
    /// - Parameter additionalRoots: extra roots to scan in addition to
    ///   the macOS defaults. Tests use this to point discovery at a
    ///   fixture tree and bypass the real `/Applications`.
    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        additionalRoots: [URL] = [],
        useDefaultRoots: Bool = true
    ) {
        self.fileManager = fileManager
        var roots: [URL] = []
        if useDefaultRoots {
            roots.append(URL(fileURLWithPath: "/Applications", isDirectory: true))
            roots.append(URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true))
            roots.append(homeDirectory.appendingPathComponent("Applications", isDirectory: true))
            // On modern macOS most Apple system apps (Finder, Notes,
            // Calendar, etc.) live under `/System/Applications` on the
            // read-only Signed System Volume, not `/Applications`. Without
            // these roots the "Show system apps" toggle would silently
            // fail to surface most system apps even after the
            // `com.apple.*` filter is disabled. Trashing them is blocked
            // by SSV — the workspace recycler reports failure for those
            // bundles, which the view-model already routes to `.failed`.
            roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
            roots.append(URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true))
        }
        roots.append(contentsOf: additionalRoots)
        self.roots = roots
    }

    func installedApps(includingSystemApps: Bool) async throws -> [AppInfo] {
        // Hop off the calling actor so the directory walk and `Info.plist`
        // reads don't pin the main thread for hundreds of milliseconds on
        // machines with many installed apps.
        let fileManager = fileManager
        let roots = roots
        let log = log
        return await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            var apps: [AppInfo] = []
            for root in roots {
                guard fileManager.fileExists(atPath: root.path) else { continue }
                // `.skipsPackageDescendants` keeps the enumerator from
                // walking *inside* `.app` bundles (Contents/MacOS, etc.) —
                // we want to find the bundle itself, not its frameworks
                // or XPC services. Without recursion we'd miss apps
                // installed in vendor subfolders like
                // `/Applications/Adobe/.../*.app` or `/Applications/Setapp/*.app`.
                guard let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { url, error in
                        // Privacy: paths and raw error text can leak user-
                        // identifying info into Console; redact both. Keep
                        // walking the rest of the tree — a single
                        // unreadable subfolder must not blank the whole
                        // app list.
                        log.debug("AppDiscovery skipping unreadable entry \(url.path, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private)")
                        return true
                    }
                ) else { continue }

                for case let entry as URL in enumerator {
                    guard entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                        continue
                    }
                    guard let info = Self.parseBundle(at: entry, fileManager: fileManager) else {
                        continue
                    }
                    if !includingSystemApps, info.bundleID.hasPrefix("com.apple.") {
                        continue
                    }
                    // Dedup by bundle URL path — two roots may surface the
                    // same `.app` (e.g. `/Applications` and a fixture root
                    // pointing at the same tree in tests).
                    guard seen.insert(info.bundleURL.path).inserted else { continue }
                    apps.append(info)
                }
            }
            apps.sort { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return apps
        }.value
    }

    /// Parses `Info.plist` for a single `.app` bundle. Returns `nil` when
    /// `CFBundleIdentifier` is missing — without a bundle ID we can't find
    /// associated files later, so the row would be useless to the user.
    static func parseBundle(at url: URL, fileManager: FileManager) -> AppInfo? {
        let infoPlistURL = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else { return nil }
        guard let bundleID = plist["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty else { return nil }

        let displayName = (plist["CFBundleDisplayName"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let bundleName = (plist["CFBundleName"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let filenameWithoutExtension = url.deletingPathExtension().lastPathComponent
        let name = displayName ?? bundleName ?? filenameWithoutExtension

        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)

        let receipt = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt")
        let isAppStore = fileManager.fileExists(atPath: receipt.path)

        return AppInfo(
            name: name,
            bundleID: bundleID,
            version: version,
            bundleURL: url,
            isAppStore: isAppStore
        )
    }

    /// Recursive byte size of the `.app` directory tree. Hops to a
    /// background queue so the view-model can `await` it without pinning
    /// the main actor while the directory walk runs.
    func bundleSize(at url: URL) async -> Int64 {
        let fileManager = fileManager
        return await Task.detached(priority: .userInitiated) {
            Self.bundleSize(at: url, fileManager: fileManager)
        }.value
    }

    /// Recursive byte size of the `.app` directory tree. Errors are
    /// tolerated — a permission failure inside a single nested resource
    /// (e.g. a sandboxed `XPCService` we can't stat) must not zero out
    /// the whole row.
    static func bundleSize(at url: URL, fileManager: FileManager) -> Int64 {
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
}
