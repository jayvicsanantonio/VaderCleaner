// HelperDeletionPolicy.swift
// Helper-owned validation for privileged deletion requests.

import Foundation

enum HelperDeletionValidationError: LocalizedError, Equatable {
    case emptyPath
    case relativePath(String)
    case rootPath(String)
    case disallowedPath(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Deletion path is empty"
        case .relativePath(let path):
            return "Deletion path must be absolute: \(path)"
        case .rootPath(let path):
            return "Refusing to delete filesystem root: \(path)"
        case .disallowedPath(let path):
            return "Path is outside the helper deletion allowlist: \(path)"
        }
    }
}

struct HelperDeletionPolicy {
    static let production = HelperDeletionPolicy(
        allowedDescendantRoots: [
            URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
            URL(fileURLWithPath: "/private/var/folders", isDirectory: true)
        ],
        allowedLaunchPlistRoots: [
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ],
        allowedLanguageResourceRoots: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
            URL(fileURLWithPath: "/Library/Frameworks", isDirectory: true)
        ],
        volumesRoot: URL(fileURLWithPath: "/Volumes", isDirectory: true)
    )

    private let allowedDescendantRoots: [URL]
    private let allowedLaunchPlistRoots: [URL]
    private let allowedLanguageResourceRoots: [URL]
    private let volumesRoot: URL

    init(
        allowedDescendantRoots: [URL],
        allowedLaunchPlistRoots: [URL] = [],
        allowedLanguageResourceRoots: [URL],
        volumesRoot: URL
    ) {
        self.allowedDescendantRoots = allowedDescendantRoots.map(Self.canonicalRoot)
        self.allowedLaunchPlistRoots = allowedLaunchPlistRoots.map(Self.canonicalRoot)
        self.allowedLanguageResourceRoots = allowedLanguageResourceRoots.map(Self.canonicalRoot)
        self.volumesRoot = Self.canonicalRoot(volumesRoot)
    }

    func validateDeletionPath(_ path: String) throws -> URL {
        guard !path.isEmpty else { throw HelperDeletionValidationError.emptyPath }
        guard (path as NSString).isAbsolutePath else {
            throw HelperDeletionValidationError.relativePath(path)
        }

        let requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        let resolvedURL = Self.canonical(requestedURL)
        guard requestedURL.path != "/", resolvedURL.path != "/" else {
            throw HelperDeletionValidationError.rootPath(path)
        }
        guard isAllowedDeletionTarget(requestedURL), isAllowedDeletionTarget(resolvedURL) else {
            throw HelperDeletionValidationError.disallowedPath(path)
        }
        return requestedURL
    }

    func uniqueValidatedDeletionURLs(for paths: [String]) throws -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for path in paths {
            let url = try validateDeletionPath(path)
            if seen.insert(url.path).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    func removeValidatedPaths(
        _ paths: [String],
        remove: (URL) throws -> Void
    ) throws -> Error? {
        let urls = try uniqueValidatedDeletionURLs(for: paths)
        var firstError: Error?
        for url in urls {
            do {
                try remove(url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        return firstError
    }

    private func isAllowedDeletionTarget(_ url: URL) -> Bool {
        if allowedDescendantRoots.contains(where: { Self.isDescendant(url, of: $0) }) {
            return true
        }
        if isAllowedLaunchPlist(url) {
            return true
        }
        if isAllowedVolumeTrashDescendant(url) {
            return true
        }
        if isAllowedLanguageResource(url) {
            return true
        }
        return false
    }

    private func isAllowedVolumeTrashDescendant(_ url: URL) -> Bool {
        guard Self.isDescendant(url, of: volumesRoot) else { return false }
        let relative = Self.relativeComponents(of: url, under: volumesRoot)
        // Require /Volumes/<volume>/.Trashes/<uid>/<item> so neither the
        // .Trashes root nor a user's trash directory can be deleted.
        guard relative.count >= 4 else { return false }
        return relative[1] == ".Trashes" && !relative[2].isEmpty
    }

    private func isAllowedLaunchPlist(_ url: URL) -> Bool {
        guard Self.pathExtension(of: url.lastPathComponent).caseInsensitiveCompare("plist") == .orderedSame else {
            return false
        }
        return allowedLaunchPlistRoots.contains(where: { Self.isDirectChild(url, of: $0) })
    }

    private func isAllowedLanguageResource(_ url: URL) -> Bool {
        guard allowedLanguageResourceRoots.contains(where: { Self.isDescendant(url, of: $0) }) else {
            return false
        }
        let components = url.pathComponents
        guard let lprojIndex = components.firstIndex(where: {
            $0.range(of: ".lproj", options: [.caseInsensitive, .anchored, .backwards]) != nil
        }) else {
            return false
        }

        let lprojComponent = components[lprojIndex]
        guard Self.pathExtension(of: lprojComponent).caseInsensitiveCompare("lproj") == .orderedSame else {
            return false
        }

        let preceding = components[..<lprojIndex]
        return preceding.contains(where: {
            let pathExtension = Self.pathExtension(of: $0)
            return pathExtension.caseInsensitiveCompare("app") == .orderedSame
                || pathExtension.caseInsensitiveCompare("framework") == .orderedSame
                || pathExtension.caseInsensitiveCompare("appex") == .orderedSame
                || pathExtension.caseInsensitiveCompare("bundle") == .orderedSame
        })
    }

    private static func canonicalRoot(_ url: URL) -> URL {
        canonical(url)
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.pathComponents
        let rootPath = root.pathComponents
        return path.count > rootPath.count && path.starts(with: rootPath)
    }

    private static func isDirectChild(_ url: URL, of root: URL) -> Bool {
        let path = url.pathComponents
        let rootPath = root.pathComponents
        return path.count == rootPath.count + 1 && path.starts(with: rootPath)
    }

    private static func relativeComponents(of url: URL, under root: URL) -> [String] {
        Array(url.pathComponents.dropFirst(root.pathComponents.count))
    }

    private static func pathExtension(of component: String) -> String {
        (component as NSString).pathExtension
    }
}
