// FileScanner.swift
// Recursively walks a set of root URLs and emits ScannedFile records, honoring an exclusion list and tolerating permission errors.

import Foundation
import os.log

/// Pairs a directory to scan with the `ScanCategory` to tag every file under
/// it. Lets `FileScanner` stay agnostic about which path means which kind of
/// junk — that mapping belongs to the feature-specific scanners
/// (`SystemJunkScanner`, etc.) layered on top.
struct ScanRoot: Equatable {
    let url: URL
    let category: ScanCategory
}

/// Protocol surface so feature scanners and tests can inject a fake.
/// Concrete implementation is `FileScanner` below. The required API emits
/// batches so feature scanners can filter or publish partial progress without
/// retaining every file under every scanned root.
protocol FileScanning {
    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        options: FileScanOptions,
        batchSize: Int,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws

    /// Progress-aware variant. `onProgress` receives the cumulative count of
    /// filesystem items *walked* (not just matched), fired periodically so a
    /// UI can show that an open-ended scan is advancing rather than hung.
    ///
    /// A default implementation in the extension below bridges this to the
    /// non-progress method, dropping `onProgress`. Conformers that don't care
    /// — including the test fakes — need not implement it; only `FileScanner`
    /// overrides it to actually emit ticks.
    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        options: FileScanOptions,
        batchSize: Int,
        onProgress: (@Sendable (Int) -> Void)?,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws
}

struct FileScanOptions: Equatable {
    static let `default` = FileScanOptions()

    let packagesAsFiles: Bool

    /// When true, the walk never descends into or emits a TCC-protected
    /// photo-library bundle (see `ProtectedMediaStoreBundle`). Reading inside
    /// one trips a macOS Photos privacy prompt, so the Large & Old Files scan
    /// sets this; System Junk scans (which never reach `~/Pictures`) leave it
    /// off and keep their historical behaviour.
    let skipsProtectedMediaStores: Bool

    init(packagesAsFiles: Bool = false, skipsProtectedMediaStores: Bool = false) {
        self.packagesAsFiles = packagesAsFiles
        self.skipsProtectedMediaStores = skipsProtectedMediaStores
    }
}

/// Recognises the TCC-protected photo-library bundles a scan must not descend
/// into. Reading the contents of a Photos or Photo Booth library trips a macOS
/// Photos privacy prompt, so `FileScanner` skips these whole when
/// `FileScanOptions.skipsProtectedMediaStores` is set.
///
/// The Apple Music media folder (`~/Music/Music`) is not covered here — it is a
/// plainly-named directory at a fixed path, so callers exclude it by path
/// instead (see `UserFilesPathProviding.protectedMediaStores()`).
enum ProtectedMediaStoreBundle {
    /// True when `url` names a Photos library bundle (`.photoslibrary`, any
    /// casing) or the `Photo Booth Library` bundle. Matching is
    /// case-insensitive to mirror the default case-insensitive APFS volume.
    static func matches(_ url: URL) -> Bool {
        if url.pathExtension.caseInsensitiveCompare("photoslibrary") == .orderedSame {
            return true
        }
        return url.lastPathComponent.caseInsensitiveCompare("Photo Booth Library") == .orderedSame
    }
}

extension FileScanning {
    /// Bridges the progress-aware requirement to the plain one for conformers
    /// that don't emit progress. Keeping this here means existing fakes — which
    /// implement only the non-progress method — satisfy the new requirement for
    /// free, and a `FileScanning` existential still dispatches to `FileScanner`'s
    /// real implementation when it has one.
    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        options: FileScanOptions,
        batchSize: Int,
        onProgress: (@Sendable (Int) -> Void)?,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws {
        try await scan(
            roots: roots,
            excluding: excluding,
            options: options,
            batchSize: batchSize,
            onBatch: onBatch
        )
    }

    func scan(roots: [ScanRoot], excluding: [URL]) async throws -> [ScannedFile] {
        try await scan(roots: roots, excluding: excluding, onProgress: nil)
    }

    /// Accumulating convenience that also forwards a walked-count progress
    /// callback. Used by feature scanners that want the whole result array but
    /// still need to surface "still scanning" feedback while the walk runs.
    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> [ScannedFile] {
        var results: [ScannedFile] = []
        try await scan(
            roots: roots,
            excluding: excluding,
            options: .default,
            batchSize: FileScanner.defaultBatchSize,
            onProgress: onProgress
        ) { batch in
            results.append(contentsOf: batch)
        }
        return results
    }

    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        batchSize: Int,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws {
        try await scan(
            roots: roots,
            excluding: excluding,
            options: .default,
            batchSize: batchSize,
            onBatch: onBatch
        )
    }
}

enum PathExclusionMatcher {
    struct CanonicalPathMapper {
        let canonicalRootPath: String
        private let displayedRootPath: String

        init(canonicalRootPath: String, displayedRootPath: String) {
            self.canonicalRootPath = canonicalRootPath
            self.displayedRootPath = displayedRootPath
        }

        func canonicalPath(for url: URL) -> String {
            PathExclusionMatcher.project(
                normalizedPath(url),
                from: displayedRootPath,
                to: canonicalRootPath
            )
        }
    }

    /// Resolves symlinks and normalises `..`/`.` so exclusion comparisons are
    /// done on canonical paths. Mirrors `ExclusionsStore.canonicalize` so a
    /// path the user excluded matches the same canonical form a scanner sees.
    static func canonicalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    static func makeCanonicalPathMapper(for root: URL) -> CanonicalPathMapper {
        CanonicalPathMapper(
            canonicalRootPath: canonicalize(root),
            displayedRootPath: normalizedPath(root)
        )
    }

    /// True when `path` is exactly an excluded path or sits beneath one.
    /// Comparison is at path-component boundaries (not raw prefix) so
    /// excluding `/tmp/foo` does not also exclude `/tmp/foobar`. macOS's
    /// default APFS is case-insensitive, hence the case-insensitive compare.
    /// Uses `range(of:options:)` rather than `lowercased()` so we don't
    /// allocate a fresh lowercased copy of every enumerated path.
    static func isExcluded(path: String, by exclusions: [String]) -> Bool {
        for excluded in exclusions {
            if path.caseInsensitiveCompare(excluded) == .orderedSame {
                return true
            }
            let prefix = excluded.hasSuffix("/") ? excluded : excluded + "/"
            if path.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// True when one of the excluded paths sits inside `path`, but is not
    /// equal to `path` itself. Package-as-leaf scans use this to force descent
    /// when a user excluded something inside a package; otherwise selecting the
    /// package leaf for deletion would still remove excluded content.
    static func containsExcludedDescendant(of path: String, in exclusions: [String]) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return exclusions.contains { exclusion in
            exclusion.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func project(_ path: String, from displayedRootPath: String, to canonicalRootPath: String) -> String {
        if path.caseInsensitiveCompare(displayedRootPath) == .orderedSame {
            return canonicalRootPath
        }

        let displayedPrefix = displayedRootPath.hasSuffix("/") ? displayedRootPath : displayedRootPath + "/"
        guard path.range(of: displayedPrefix, options: [.anchored, .caseInsensitive]) != nil else {
            return path
        }

        let suffix = String(path.dropFirst(displayedPrefix.count))
        if canonicalRootPath == "/" {
            return "/" + suffix
        }
        let canonicalPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : canonicalRootPath + "/"
        return canonicalPrefix + suffix
    }
}

/// Shared recursive logical-size calculator for macOS package directories.
/// It intentionally mirrors the scanners' symlink policy: symlinks do not
/// contribute bytes, so package rollups cannot double-count content or pull in
/// data outside the scanned tree.
enum PackageDirectorySizer {

    struct Result: Equatable {
        let size: Int64
        let isAccessible: Bool
        let lastAccessDate: Date?
        let lastModifiedDate: Date?
    }

    private static let cancellationCheckInterval = 512

    private static let log = Logger(
        subsystem: "com.personal.VaderCleaner",
        category: "PackageDirectorySizer"
    )

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentAccessDateKey,
        .contentModificationDateKey
    ]

    private static let resourceKeySet = Set(resourceKeys)

    static func recursiveSize(
        of packageURL: URL,
        excluding canonicalExclusions: [String] = [],
        progress: (() -> Void)? = nil
    ) async throws -> Int64 {
        try await recursiveSizeResult(
            of: packageURL,
            excluding: canonicalExclusions,
            progress: progress
        ).size
    }

    static func recursiveSizeResult(
        of packageURL: URL,
        excluding canonicalExclusions: [String] = [],
        progress: (() -> Void)? = nil
    ) async throws -> Result {
        let hasExclusions = !canonicalExclusions.isEmpty
        var totalSize: Int64 = 0
        var visitedCount = 0
        var isAccessible = true
        var newestAccessDate: Date?
        var newestModifiedDate: Date?
        let pathMapper = hasExclusions ? PathExclusionMatcher.makeCanonicalPathMapper(for: packageURL) : nil

        let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, error in
                isAccessible = false
                Self.log.debug(
                    "Skipping unreadable package path \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                )
                return true
            }
        )

        guard let enumerator else {
            return Result(
                size: 0,
                isAccessible: false,
                lastAccessDate: nil,
                lastModifiedDate: nil
            )
        }

        while let url = enumerator.nextObject() as? URL {
            visitedCount += 1
            if visitedCount.isMultiple(of: Self.cancellationCheckInterval) {
                try Task.checkCancellation()
                await Task.yield()
            }

            let resourceValues = try? url.resourceValues(forKeys: resourceKeySet)

            if resourceValues?.isSymbolicLink == true {
                continue
            }

            if let pathMapper {
                let canonicalPath = pathMapper.canonicalPath(for: url)
                if PathExclusionMatcher.isExcluded(path: canonicalPath, by: canonicalExclusions) {
                    if resourceValues?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
            }

            guard resourceValues?.isRegularFile == true else { continue }

            totalSize += Int64(resourceValues?.fileSize ?? 0)
            newestAccessDate = Self.newer(of: newestAccessDate, and: resourceValues?.contentAccessDate)
            newestModifiedDate = Self.newer(of: newestModifiedDate, and: resourceValues?.contentModificationDate)
            progress?()
        }

        return Result(
            size: totalSize,
            isAccessible: isAccessible,
            lastAccessDate: newestAccessDate,
            lastModifiedDate: newestModifiedDate
        )
    }

    private static func newer(of lhs: Date?, and rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case (.some(let date), nil), (nil, .some(let date)):
            return date
        case (.some(let lhs), .some(let rhs)):
            return max(lhs, rhs)
        }
    }
}

/// Walks each root recursively and emits every regular file as a `ScannedFile`
/// tagged with the root's category. Symlinks are skipped
/// outright so the same physical file can never appear twice via different
/// paths and so links pointing outside the scanned tree don't pull external
/// content in. Permission errors on subdirectories are logged and the walk
/// continues — a single unreadable cache directory must never abort a whole
/// scan.
///
/// Non-isolated by design: the type holds no shared state and runs on
/// whichever task it's awaited from. Prompt 26 will pass the resolved
/// `ExclusionsStore.exclusions` snapshot through the `excluding` argument so
/// this layer never touches a `@MainActor` store directly.
struct FileScanner: FileScanning {

    static let defaultBatchSize = 2_048

    private static let cancellationCheckInterval = 512

    private static let log = Logger(
        subsystem: "com.personal.VaderCleaner",
        category: "FileScanner"
    )

    /// Resource keys we ask the enumerator to prefetch — pulling them in
    /// bulk is materially faster than one stat() per file when scanning
    /// large caches.
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .isPackageKey,
        .fileSizeKey,
        .contentAccessDateKey,
        .contentModificationDateKey
    ]

    /// Pre-built `Set` form of `resourceKeys` for the per-file
    /// `resourceValues(forKeys:)` call. Allocating it once instead of on
    /// every iteration matters when scanning hundreds of thousands of files.
    private static let resourceKeySet = Set(resourceKeys)

    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        options: FileScanOptions = .default,
        batchSize: Int = defaultBatchSize,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws {
        try await scan(
            roots: roots,
            excluding: excluding,
            options: options,
            batchSize: batchSize,
            onProgress: nil,
            onBatch: onBatch
        )
    }

    func scan(
        roots: [ScanRoot],
        excluding: [URL],
        options: FileScanOptions = .default,
        batchSize: Int = defaultBatchSize,
        onProgress: (@Sendable (Int) -> Void)?,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws {
        let batchLimit = max(1, batchSize)
        let canonicalExclusions = excluding.map(PathExclusionMatcher.canonicalize)
        let hasExclusions = !canonicalExclusions.isEmpty
        var batch: [ScannedFile] = []
        batch.reserveCapacity(batchLimit)
        var visitedCount = 0

        func flushBatch() async throws {
            guard !batch.isEmpty else { return }
            let emitted = batch
            batch.removeAll(keepingCapacity: true)
            try Task.checkCancellation()
            try await onBatch(emitted)
            try Task.checkCancellation()
        }

        for root in roots {
            try Task.checkCancellation()

            let pathMapper = hasExclusions ? PathExclusionMatcher.makeCanonicalPathMapper(for: root.url) : nil
            if let pathMapper {
                if PathExclusionMatcher.isExcluded(path: pathMapper.canonicalRootPath, by: canonicalExclusions) {
                    continue
                }
            }

            // In default mode, `.skipsPackageDescendants` preserves the
            // historical system-junk behaviour: package internals are not
            // emitted. Package-as-file mode needs to see the package URL first
            // so it can emit one rolled-up item and call `skipDescendants()`.
            // `.skipsHiddenFiles` is intentionally NOT set: cache and log
            // directories on macOS routinely contain dot-prefixed files we
            // need to count.
            let enumerationOptions: FileManager.DirectoryEnumerationOptions =
                options.packagesAsFiles ? [] : [.skipsPackageDescendants]
            let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: Self.resourceKeys,
                options: enumerationOptions,
                errorHandler: { url, error in
                    Self.log.debug(
                        "Skipping unreadable path \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                    )
                    return true
                }
            )

            guard let enumerator else { continue }

            while let url = enumerator.nextObject() as? URL {
                visitedCount += 1
                if visitedCount.isMultiple(of: Self.cancellationCheckInterval) {
                    try Task.checkCancellation()
                    // Publish the running walked-count on the same cadence we
                    // already check cancellation, so a UI can show the scan is
                    // advancing. Piggy-backing on the existing interval keeps
                    // this free of any extra per-file cost.
                    onProgress?(visitedCount)
                }

                let resourceValues = try? url.resourceValues(forKeys: Self.resourceKeySet)

                if resourceValues?.isSymbolicLink == true {
                    // Skip symlinks unconditionally — this avoids both
                    // double-counting (when the link's target is also under
                    // the scanned root) and pulling in external content
                    // (when the target is outside the root).
                    continue
                }

                // Exclusions are canonical, while enumerator URLs keep the
                // root spelling they were given. Projecting through the root
                // mapper preserves canonical matching without doing
                // symlink-resolution I/O for every item.
                let canonicalPath = pathMapper?.canonicalPath(for: url)
                if let canonicalPath,
                   PathExclusionMatcher.isExcluded(path: canonicalPath, by: canonicalExclusions) {
                    if resourceValues?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let isDirectory = resourceValues?.isDirectory == true

                // Never descend into a TCC-protected photo-library bundle —
                // reading its contents trips a macOS Photos privacy prompt.
                // The bundle is dropped, not emitted: a photo library is not
                // a deletable file.
                if options.skipsProtectedMediaStores,
                   isDirectory,
                   ProtectedMediaStoreBundle.matches(url) {
                    enumerator.skipDescendants()
                    continue
                }

                if options.packagesAsFiles,
                   isDirectory,
                   resourceValues?.isPackage == true {
                    if let canonicalPath,
                       PathExclusionMatcher.containsExcludedDescendant(
                        of: canonicalPath,
                        in: canonicalExclusions
                    ) {
                        continue
                    }

                    let packageResult = try await PackageDirectorySizer.recursiveSizeResult(
                        of: url,
                        excluding: canonicalExclusions
                    )
                    batch.append(
                        ScannedFile(
                            url: url,
                            size: packageResult.size,
                            lastAccessDate: packageResult.lastAccessDate,
                            lastModifiedDate: packageResult.lastModifiedDate,
                            category: root.category
                        )
                    )
                    enumerator.skipDescendants()
                    if batch.count >= batchLimit {
                        try await flushBatch()
                    }
                    continue
                }

                guard resourceValues?.isRegularFile == true else { continue }

                let size = Int64(resourceValues?.fileSize ?? 0)

                batch.append(
                    ScannedFile(
                        url: url,
                        size: size,
                        lastAccessDate: resourceValues?.contentAccessDate,
                        lastModifiedDate: resourceValues?.contentModificationDate,
                        category: root.category
                    )
                )
                if batch.count >= batchLimit {
                    try await flushBatch()
                }
            }
        }

        try await flushBatch()
        // Final tick so a short scan (fewer items than the cancellation
        // interval) still reports a count, and a long one ends on its true
        // total rather than the last interval boundary.
        onProgress?(visitedCount)
    }
}
