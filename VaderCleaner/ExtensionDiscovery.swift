// ExtensionDiscovery.swift
// The five Extensions Manager discovery types — Safari, browser, Mail-plugin, internet-plug-in, and launch-agent scanners — plus the shared protocol and sizing helper they emit ExtensionItems through.

import Foundation
import os.log

/// Test seam between `ExtensionsManagerViewModel` and the real on-disk
/// extension locations. Each concrete discoverer scans one surface and
/// returns ready-to-display `ExtensionItem`s so the view-model never walks
/// the filesystem directly — every call site is exercisable with a temp
/// fixture in tests.
protocol ExtensionDiscovering: Sendable {
    func extensions() async -> [ExtensionItem]
}

// MARK: - Shared sizing

/// Recursive byte size of an artifact. A bare file contributes its own
/// size; a bundle/directory sums its regular-file descendants. Errors are
/// tolerated — an unreadable nested resource must not zero the row.
enum ExtensionArtifactSizer {
    static func size(at url: URL, fileManager: FileManager) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
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

    /// `CFBundleIdentifier` from a bundle's `Contents/Info.plist`, or `nil`.
    static func bundleID(at bundleURL: URL) -> String? {
        let infoPlist = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String,
              !id.isEmpty else { return nil }
        return id
    }
}

private let extensionDiscoveryLog = Logger(
    subsystem: "com.personal.VaderCleaner",
    category: "ExtensionDiscovery"
)

// MARK: - Safari

/// Scans the legacy `~/Library/Safari/Extensions/` directory.
///
/// On macOS 14+ most Safari extensions ship as `.appex` inside a parent app
/// via PluginKit and `SFSafariExtensionManager` cannot enumerate
/// third-party extensions — so this directory is frequently absent and the
/// honest result is `[]`. Legacy `.safariextz` archives and any `.appex`
/// still living here are surfaced.
struct SafariExtensionDiscovery: ExtensionDiscovering {

    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func extensions() async -> [ExtensionItem] {
        let dir = homeDirectory
            .appendingPathComponent("Library/Safari/Extensions", isDirectory: true)
        let fileManager = fileManager
        return await Task.detached(priority: .userInitiated) {
            guard fileManager.fileExists(atPath: dir.path) else { return [] }
            let entries = (try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            var items: [ExtensionItem] = []
            for entry in entries {
                let ext = entry.pathExtension.lowercased()
                guard ext == "safariextz" || ext == "appex" else { continue }
                items.append(ExtensionItem(
                    name: entry.deletingPathExtension().lastPathComponent,
                    path: entry,
                    bundleID: ext == "appex"
                        ? ExtensionArtifactSizer.bundleID(at: entry) : nil,
                    type: .safariExtension,
                    isEnabled: true,
                    size: ExtensionArtifactSizer.size(at: entry, fileManager: fileManager)
                ))
            }
            return items.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }
}

// MARK: - Browser

/// Enumerates Chromium-family and Firefox profile extension directories.
struct BrowserExtensionDiscovery: ExtensionDiscovering {

    /// Chromium-family product directories under `Application Support`. All
    /// surface as `.chromeExtension` — the enum has no per-vendor case and
    /// the on-disk layout is identical across them.
    private static let chromiumRoots = [
        "Google/Chrome",
        "Chromium",
        "BraveSoftware/Brave-Browser",
        "Microsoft Edge"
    ]

    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func extensions() async -> [ExtensionItem] {
        let support = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let fileManager = fileManager
        return await Task.detached(priority: .userInitiated) {
            var items: [ExtensionItem] = []
            for root in Self.chromiumRoots {
                let productDir = support.appendingPathComponent(root, isDirectory: true)
                items.append(contentsOf: Self.chromiumExtensions(
                    in: productDir, fileManager: fileManager
                ))
            }
            items.append(contentsOf: Self.firefoxExtensions(
                in: support.appendingPathComponent("Firefox/Profiles", isDirectory: true),
                fileManager: fileManager
            ))
            return items.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }

    /// Walks `<product>/<profile>/Extensions/<id>/<version>/manifest.json`.
    private static func chromiumExtensions(
        in productDir: URL,
        fileManager: FileManager
    ) -> [ExtensionItem] {
        guard fileManager.fileExists(atPath: productDir.path) else { return [] }
        let profiles = (try? fileManager.contentsOfDirectory(
            at: productDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var items: [ExtensionItem] = []
        for profile in profiles {
            let extensionsDir = profile
                .appendingPathComponent("Extensions", isDirectory: true)
            guard fileManager.fileExists(atPath: extensionsDir.path) else { continue }
            let extIDs = (try? fileManager.contentsOfDirectory(
                at: extensionsDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for extDir in extIDs {
                let versionDirs = (try? fileManager.contentsOfDirectory(
                    at: extDir, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                guard let latest = versionDirs.sorted(by: {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }).last else { continue }
                let manifestName = Self.chromeManifestName(
                    at: latest.appendingPathComponent("manifest.json")
                )
                items.append(ExtensionItem(
                    name: manifestName ?? extDir.lastPathComponent,
                    path: extDir,
                    bundleID: extDir.lastPathComponent,
                    type: .chromeExtension,
                    isEnabled: true,
                    size: ExtensionArtifactSizer.size(at: extDir, fileManager: fileManager)
                ))
            }
        }
        return items
    }

    /// Reads the `name` field from a Chrome `manifest.json`. Localised
    /// manifests use a `__MSG_*__` placeholder we can't resolve without the
    /// `_locales` lookup — callers fall back to the extension id in that
    /// case.
    private static func chromeManifestName(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String,
              !name.isEmpty,
              !name.hasPrefix("__MSG_") else { return nil }
        return name
    }

    /// `<profile>/extensions/*.xpi` (or unpacked dirs) under every Firefox
    /// profile.
    private static func firefoxExtensions(
        in profilesDir: URL,
        fileManager: FileManager
    ) -> [ExtensionItem] {
        guard fileManager.fileExists(atPath: profilesDir.path) else { return [] }
        let profiles = (try? fileManager.contentsOfDirectory(
            at: profilesDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var items: [ExtensionItem] = []
        for profile in profiles {
            let extensionsDir = profile
                .appendingPathComponent("extensions", isDirectory: true)
            guard fileManager.fileExists(atPath: extensionsDir.path) else { continue }
            let entries = (try? fileManager.contentsOfDirectory(
                at: extensionsDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries {
                let isXPI = entry.pathExtension.lowercased() == "xpi"
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: entry.path, isDirectory: &isDir)
                guard isXPI || isDir.boolValue else { continue }
                items.append(ExtensionItem(
                    name: entry.deletingPathExtension().lastPathComponent,
                    path: entry,
                    bundleID: entry.deletingPathExtension().lastPathComponent,
                    type: .firefoxExtension,
                    isEnabled: true,
                    size: ExtensionArtifactSizer.size(at: entry, fileManager: fileManager)
                ))
            }
        }
        return items
    }
}

// MARK: - Mail plugins

/// Scans the user and system `Mail/Bundles/` directories for `.mailbundle`s.
struct MailPluginDiscovery: ExtensionDiscovering {

    private let userBundlesDirectory: URL
    private let systemBundlesDirectory: URL?
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemBundlesDirectory: URL? = URL(fileURLWithPath: "/Library/Mail/Bundles", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.userBundlesDirectory = homeDirectory
            .appendingPathComponent("Library/Mail/Bundles", isDirectory: true)
        self.systemBundlesDirectory = systemBundlesDirectory
        self.fileManager = fileManager
    }

    func extensions() async -> [ExtensionItem] {
        let roots = [userBundlesDirectory, systemBundlesDirectory].compactMap { $0 }
        let fileManager = fileManager
        return await Task.detached(priority: .userInitiated) {
            Self.bundles(
                in: roots,
                extensions: ["mailbundle"],
                type: .mailPlugin,
                fileManager: fileManager
            )
        }.value
    }

    static func bundles(
        in roots: [URL],
        extensions: Set<String>,
        type: ExtensionType,
        fileManager: FileManager
    ) -> [ExtensionItem] {
        var seen = Set<String>()
        var items: [ExtensionItem] = []
        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let entries = (try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries {
                guard extensions.contains(entry.pathExtension.lowercased()) else { continue }
                guard seen.insert(entry.path).inserted else { continue }
                items.append(ExtensionItem(
                    name: entry.deletingPathExtension().lastPathComponent,
                    path: entry,
                    bundleID: ExtensionArtifactSizer.bundleID(at: entry),
                    type: type,
                    isEnabled: true,
                    size: ExtensionArtifactSizer.size(at: entry, fileManager: fileManager)
                ))
            }
        }
        return items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Internet plug-ins

/// Scans the user and system `Internet Plug-Ins/` directories.
struct InternetPluginDiscovery: ExtensionDiscovering {

    private let userPluginsDirectory: URL
    private let systemPluginsDirectory: URL?
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemPluginsDirectory: URL? = URL(fileURLWithPath: "/Library/Internet Plug-Ins", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.userPluginsDirectory = homeDirectory
            .appendingPathComponent("Library/Internet Plug-Ins", isDirectory: true)
        self.systemPluginsDirectory = systemPluginsDirectory
        self.fileManager = fileManager
    }

    func extensions() async -> [ExtensionItem] {
        let roots = [userPluginsDirectory, systemPluginsDirectory].compactMap { $0 }
        let fileManager = fileManager
        return await Task.detached(priority: .userInitiated) {
            MailPluginDiscovery.bundles(
                in: roots,
                extensions: ["plugin", "webplugin", "bundle"],
                type: .internetPlugin,
                fileManager: fileManager
            )
        }.value
    }
}

// MARK: - Launch agents / login items

/// Reads `~/Library/LaunchAgents` plists. These are the discoverable
/// surface for third-party login items — `SMAppService` cannot enumerate
/// items registered by other apps.
struct LaunchAgentDiscovery: ExtensionDiscovering {

    private let roots: [URL]
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemRoots: [URL] = [
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ],
        fileManager: FileManager = .default
    ) {
        self.roots = [
            homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        ] + systemRoots
        self.fileManager = fileManager
    }

    /// Every `*.plist` under the user's `~/Library/LaunchAgents` plus the
    /// system `/Library/LaunchAgents` and `/Library/LaunchDaemons` roots,
    /// deduped by path. `name` comes from the `Label` key (falling back to
    /// the filename); `isEnabled` is the inverse of the `Disabled` key —
    /// launchd's authoritative source. The system roots are removable: the
    /// privileged helper's allowlist permits direct-child plists under both,
    /// and `requiresHelper` routes those paths through it.
    func userAgents() async -> [ExtensionItem] {
        let roots = roots
        let fileManager = fileManager
        return await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            var items: [ExtensionItem] = []
            for dir in roots {
                guard fileManager.fileExists(atPath: dir.path) else { continue }
                let entries = (try? fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for entry in entries where entry.pathExtension.lowercased() == "plist" {
                    guard seen.insert(entry.path).inserted else { continue }
                    let plist = (try? Data(contentsOf: entry)).flatMap {
                        try? PropertyListSerialization.propertyList(
                            from: $0, options: [], format: nil
                        ) as? [String: Any]
                    } ?? [:]
                    let label = (plist["Label"] as? String).flatMap {
                        $0.isEmpty ? nil : $0
                    }
                    let disabled = (plist["Disabled"] as? Bool) ?? false
                    items.append(ExtensionItem(
                        name: label ?? entry.deletingPathExtension().lastPathComponent,
                        path: entry,
                        bundleID: nil,
                        type: .loginItemFromApp,
                        isEnabled: !disabled,
                        size: ExtensionArtifactSizer.size(at: entry, fileManager: fileManager)
                    ))
                }
            }
            return items.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }

    func extensions() async -> [ExtensionItem] {
        await userAgents()
    }
}
