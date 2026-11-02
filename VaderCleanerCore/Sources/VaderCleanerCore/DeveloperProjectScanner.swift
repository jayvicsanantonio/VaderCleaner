// DeveloperProjectScanner.swift
// Walks user-chosen code directories to find regenerable web/dev project artifacts (node_modules, dist, build, .next, …) and emits one rolled-up ScannedFile per matched folder.

import Foundation

/// Discovers regenerable project artifacts scattered across the user's code
/// directories and reports each as a single rolled-up `ScannedFile`.
///
/// Unlike the fixed-root junk `FileScanner` walks, these folders live at
/// arbitrary depths inside arbitrary project trees, so this scanner matches
/// directories *by name* against `junkFolderNames`. On a match it sizes the
/// whole folder, emits one entry tagged `.webDevJunk`, and stops descending —
/// a `node_modules` is one removable unit, and nested `node_modules` inside it
/// are counted in the parent's total rather than reported separately.
///
/// Traversal is depth-capped so a misconfigured root can never trigger a walk
/// of the entire home directory. Unreadable directories are skipped, matching
/// `FileScanner`'s permission-error tolerance.
struct DeveloperProjectScanner {

    /// Folder names treated as a single removable unit. Matching one stops
    /// descent into it. Lowercase, exact-match — these names are conventionally
    /// lowercase across the JS/Python/Rust toolchains.
    static let junkFolderNames: Set<String> = [
        "node_modules",
        "dist",
        "build",
        ".next",
        ".nuxt",
        ".turbo",
        ".parcel-cache",
        "__pycache__",
        ".pytest_cache",
        "target",
    ]

    /// Names people also give to their own folders, each with the manifests that
    /// show a toolchain is really behind it. A `target` beside a `Cargo.toml` is
    /// Rust output; a `target` with nothing around it could be anything, so it is
    /// never offered. Every other junk name is one only a toolchain creates.
    static let manifestsForAmbiguousNames: [String: Set<String>] = [
        "build": [
            "package.json", "build.gradle", "build.gradle.kts", "settings.gradle",
            "settings.gradle.kts", "CMakeLists.txt", "meson.build", "pyproject.toml", "setup.py",
        ],
        "dist": ["package.json", "pyproject.toml", "setup.py"],
        "target": ["Cargo.toml", "pom.xml"],
    ]

    /// Visible folders whose contents are never project output. A virtualenv's
    /// installed packages carry their own `build` and `dist` folders beside their
    /// own `setup.py`, so the manifest rule can't rule those out by itself.
    private static let undescendedFolderNames: Set<String> = ["venv", "site-packages"]

    /// Directories to search. Supplied per scan from the user-configurable scope.
    let roots: [URL]

    /// How many directory levels below each root to descend before giving up.
    /// Keeps an over-broad root (e.g. the home directory) from walking forever.
    let maxDepth: Int

    private let fileManager: FileManager

    init(roots: [URL], maxDepth: Int = 6, fileManager: FileManager = .default) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.fileManager = fileManager
    }

    /// Cadence of progress ticks during the walk, matching `FileScanner`'s
    /// interval so the count advances smoothly without a closure call per
    /// visited file.
    private static let progressTickInterval = 512

    /// Runs the discovery walk and returns one rolled-up `ScannedFile` per
    /// matched project folder. Non-throwing so it merges into `SystemJunkScanner`
    /// alongside the other supplementary enumerators. `onProgress` receives the
    /// walk's cumulative visited-item count — directory entries walked plus
    /// every file sized inside a matched artifact folder — so the scanning
    /// screen's tally keeps moving through what can be a long crawl over big
    /// `node_modules` trees.
    func scan(onProgress: (@Sendable (Int) -> Void)? = nil) async -> [ScannedFile] {
        var results: [ScannedFile] = []
        var visited = 0
        for root in roots {
            collect(in: root, depth: 0, into: &results, visited: &visited, onProgress: onProgress)
        }
        // Final tick so a short walk still reports a count, and a long one
        // ends on its true total rather than the last interval boundary.
        onProgress?(visited)
        return results
    }

    /// Lists `directory`, emitting a rolled-up entry for any immediate child
    /// whose name is a known artifact folder and recursing into the rest until
    /// `maxDepth` is reached. A match is never descended into, so its whole
    /// subtree — including nested matches — folds into its single rolled-up size.
    private func collect(
        in directory: URL,
        depth: Int,
        into results: inout [ScannedFile],
        visited: inout Int,
        onProgress: (@Sendable (Int) -> Void)?
    ) {
        if Task.isCancelled { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: []
        ) else {
            return
        }
        let siblingNames = Set(entries.map(\.lastPathComponent))
        for entry in entries {
            visit(&visited, onProgress: onProgress)
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true else { continue }

            if Self.isArtifact(named: entry.lastPathComponent, besideEntriesNamed: siblingNames) {
                results.append(rolledUpFile(for: entry, visited: &visited, onProgress: onProgress))
            } else if depth < maxDepth,
                      Self.mayContainProjects(named: entry.lastPathComponent, isPackage: values?.isPackage == true, depth: depth) {
                collect(in: entry, depth: depth + 1, into: &results, visited: &visited, onProgress: onProgress)
            }
        }
    }

    /// Whether a folder is regenerable output: a name only a toolchain creates,
    /// or an ambiguous name beside one of the manifests that vouch for it.
    private static func isArtifact(named name: String, besideEntriesNamed siblings: Set<String>) -> Bool {
        guard junkFolderNames.contains(name) else { return false }
        guard let manifests = manifestsForAmbiguousNames[name] else { return true }
        return !manifests.isDisjoint(with: siblings)
    }

    /// Whether the walk should look inside a folder that isn't an artifact. Hidden
    /// folders hold metadata and tool state rather than projects: `.git` has
    /// `refs/heads/build` whenever a branch is named `build/…`, and removing that
    /// deletes the branches. App bundles hold a shipped app's runtime files, and a
    /// root-level `Library` — the home folder picked as the scan folder — holds
    /// other apps' data.
    private static func mayContainProjects(named name: String, isPackage: Bool, depth: Int) -> Bool {
        if name.hasPrefix(".") || isPackage || undescendedFolderNames.contains(name) { return false }
        return !(depth == 0 && name == "Library")
    }

    /// Counts one visited filesystem item, ticking `onProgress` on the shared
    /// interval.
    private func visit(_ visited: inout Int, onProgress: (@Sendable (Int) -> Void)?) {
        visited += 1
        if visited.isMultiple(of: Self.progressTickInterval) {
            onProgress?(visited)
        }
    }

    /// Builds the single `ScannedFile` representing a matched folder: the folder
    /// URL, its recursive byte total, and timestamps so the Cleanup Manager can
    /// sort and age it like any other entry.
    ///
    /// The modified date is the newest of the folder's and its files'. A folder's
    /// own date only moves when a direct child is added or removed, so on its own
    /// it calls a `dist` idle while the files inside change daily.
    private func rolledUpFile(
        for folder: URL,
        visited: inout Int,
        onProgress: (@Sendable (Int) -> Void)?
    ) -> ScannedFile {
        let timestamps = try? folder.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        let contents = directoryContents(folder, visited: &visited, onProgress: onProgress)
        return ScannedFile(
            url: folder,
            size: contents.size,
            lastAccessDate: timestamps?.contentAccessDate,
            lastModifiedDate: [timestamps?.contentModificationDate, contents.newestModification].compactMap { $0 }.max(),
            category: .webDevJunk
        )
    }

    /// Sums the byte size of every regular file under `folder` and finds the
    /// newest of their modification dates. Unreadable descendants are skipped
    /// rather than aborting the walk. This is where the bulk of a big artifact
    /// folder's items are visited, so each enumerated descendant counts toward
    /// the progress tally.
    private func directoryContents(
        _ folder: URL,
        visited: inout Int,
        onProgress: (@Sendable (Int) -> Void)?
    ) -> (size: Int64, newestModification: Date?) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return (0, nil)
        }
        var total: Int64 = 0
        var newest: Date?
        for case let url as URL in enumerator {
            visit(&visited, onProgress: onProgress)
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
                if let modified = values?.contentModificationDate, modified > (newest ?? .distantPast) {
                    newest = modified
                }
            }
        }
        return (total, newest)
    }
}
