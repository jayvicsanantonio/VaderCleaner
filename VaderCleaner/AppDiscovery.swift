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
                let entries: [URL]
                do {
                    entries = try fileManager.contentsOfDirectory(
                        at: root,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    log.debug("AppDiscovery skipping unreadable root \(root.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
                for entry in entries {
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

        let size = bundleSize(at: url, fileManager: fileManager)

        return AppInfo(
            name: name,
            bundleID: bundleID,
            version: version,
            bundleURL: url,
            bundleSizeBytes: size,
            isAppStore: isAppStore
        )
    }

    /// Recursive byte size of the `.app` directory tree. Errors are
    /// tolerated — a permission failure inside a single nested resource
    /// (e.g. a sandboxed `XPCService` we can't stat) must not zero out
    /// the whole row.
    private static func bundleSize(at url: URL, fileManager: FileManager) -> Int64 {
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
