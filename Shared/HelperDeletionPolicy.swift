// HelperDeletionPolicy.swift
// Helper-owned validation for privileged deletion requests.

import Foundation
import Darwin

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
        remove: (URL) throws -> Void = Self.securelyRemoveItem
    ) throws -> Error? {
        var seen = Set<String>()
        var firstError: Error?
        for path in paths {
            do {
                let url = try validateDeletionPath(path)
                guard seen.insert(url.path).inserted else { continue }
                try remove(url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        return firstError
    }

    static func securelyRemoveItem(_ url: URL) throws {
        var components = url.standardizedFileURL.pathComponents
        if components.count > 1, components[1] == "var" {
            components.replaceSubrange(1...1, with: ["private", "var"])
        }
        let displayPath = absolutePath(from: components)
        guard components.first == "/", components.count > 1 else {
            throw HelperDeletionValidationError.rootPath(url.path)
        }
        components.removeFirst()

        let rootFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw posixError(operation: "open", path: "/")
        }
        defer { close(rootFD) }

        try removeItem(components: components, from: rootFD, displayPath: displayPath)
    }

    private func isAllowedDeletionTarget(_ url: URL) -> Bool {
        if isAllowedDeletionTargetWithoutSystemAliases(url) {
            return true
        }
        if let aliasURL = Self.canonicalSystemAlias(for: url) {
            return isAllowedDeletionTargetWithoutSystemAliases(aliasURL)
        }
        return false
    }

    private func isAllowedDeletionTargetWithoutSystemAliases(_ url: URL) -> Bool {
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
        guard let allowedRoot = allowedLanguageResourceRoots.first(where: { Self.isDescendant(url, of: $0) }) else {
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

        if Self.isApplicationSupportRoot(allowedRoot) {
            return true
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

    private static func removeItem(components: [String], from rootFD: Int32, displayPath: String) throws {
        var parentFD = rootFD
        var openedParentFDs: [Int32] = []
        defer {
            for fd in openedParentFDs.reversed() {
                close(fd)
            }
        }

        for component in components.dropLast() {
            let nextFD = try openDirectory(component, relativeTo: parentFD, displayPath: displayPath)
            openedParentFDs.append(nextFD)
            parentFD = nextFD
        }

        guard let itemName = components.last else {
            throw HelperDeletionValidationError.rootPath(displayPath)
        }
        try removeEntry(named: itemName, in: parentFD, displayPath: displayPath)
    }

    private static func removeEntry(named name: String, in directoryFD: Int32, displayPath: String) throws {
        var info = stat()
        try name.withCString { namePointer in
            guard fstatat(directoryFD, namePointer, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixError(operation: "fstatat", path: displayPath)
            }
        }

        if isDirectoryMode(info.st_mode) {
            try removeDirectoryRecursively(named: name, in: directoryFD, displayPath: displayPath)
        } else {
            try name.withCString { namePointer in
                guard unlinkat(directoryFD, namePointer, 0) == 0 else {
                    throw posixError(operation: "unlinkat", path: displayPath)
                }
            }
        }
    }

    private static func removeDirectoryRecursively(named name: String, in parentFD: Int32, displayPath: String) throws {
        let directoryFD = try openDirectory(name, relativeTo: parentFD, displayPath: displayPath)
        guard let directory = fdopendir(directoryFD) else {
            let error = posixError(operation: "fdopendir", path: displayPath)
            close(directoryFD)
            throw error
        }
        defer { closedir(directory) }

        let currentFD = dirfd(directory)
        while let entry = readdir(directory) {
            let entryName = Self.entryName(entry)
            guard entryName != ".", entryName != ".." else { continue }
            try removeEntry(named: entryName, in: currentFD, displayPath: displayPath + "/" + entryName)
        }

        try name.withCString { namePointer in
            guard unlinkat(parentFD, namePointer, AT_REMOVEDIR) == 0 else {
                throw posixError(operation: "unlinkat", path: displayPath)
            }
        }
    }

    private static func openDirectory(_ name: String, relativeTo directoryFD: Int32, displayPath: String) throws -> Int32 {
        try name.withCString { namePointer in
            let fd = openat(directoryFD, namePointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                throw posixError(operation: "openat", path: displayPath)
            }
            return fd
        }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func isDirectoryMode(_ mode: mode_t) -> Bool {
        (mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private static func absolutePath(from components: [String]) -> String {
        guard components.first == "/" else {
            return components.joined(separator: "/")
        }
        return "/" + components.dropFirst().joined(separator: "/")
    }

    private static func posixError(operation: String, path: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed for \(path): \(String(cString: strerror(code)))"
            ]
        )
    }

    private static func canonicalSystemAlias(for url: URL) -> URL? {
        let path = url.path
        let varPrefix = "/var"
        guard path == varPrefix || path.hasPrefix(varPrefix + "/") else {
            return nil
        }
        // macOS exposes /var as an alias of /private/var; keep this narrow so
        // arbitrary symlinks still have to pass validation in both spellings.
        let suffix = path.dropFirst(varPrefix.count)
        return URL(fileURLWithPath: "/private/var" + suffix, isDirectory: url.hasDirectoryPath).standardizedFileURL
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

    private static func isApplicationSupportRoot(_ url: URL) -> Bool {
        url.pathComponents.suffix(2).elementsEqual(["Library", "Application Support"])
    }

    private static func pathExtension(of component: String) -> String {
        (component as NSString).pathExtension
    }
}
