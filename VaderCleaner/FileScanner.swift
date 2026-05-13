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
}

struct FileScanOptions: Equatable {
    static let `default` = FileScanOptions()

    let packagesAsFiles: Bool

    init(packagesAsFiles: Bool = false) {
        self.packagesAsFiles = packagesAsFiles
    }
}

extension FileScanning {
    func scan(roots: [ScanRoot], excluding: [URL]) async throws -> [ScannedFile] {
        var results: [ScannedFile] = []
        try await scan(
            roots: roots,
            excluding: excluding,
            options: .default,
            batchSize: FileScanner.defaultBatchSize
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
    /// Resolves symlinks and normalises `..`/`.` so exclusion comparisons are
    /// done on canonical paths. Mirrors `ExclusionsStore.canonicalize` so a
    /// path the user excluded matches the same canonical form a scanner sees.
    static func canonicalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
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
}

/// Shared recursive logical-size calculator for macOS package directories.
/// It intentionally mirrors the scanners' symlink policy: symlinks do not
/// contribute bytes, so package rollups cannot double-count content or pull in
/// data outside the scanned tree.
enum PackageDirectorySizer {

    private static let cancellationCheckInterval = 512

    private static let log = Logger(
        subsystem: "com.personal.VaderCleaner",
        category: "PackageDirectorySizer"
    )

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey
    ]

    private static let resourceKeySet = Set(resourceKeys)

    static func recursiveSize(
        of packageURL: URL,
        excluding canonicalExclusions: [String] = [],
        progress: (() -> Void)? = nil
    ) async throws -> Int64 {
        let hasExclusions = !canonicalExclusions.isEmpty
        var totalSize: Int64 = 0
        var visitedCount = 0

        let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, error in
                Self.log.debug(
                    "Skipping unreadable package path \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                )
                return true
            }
        )

        guard let enumerator else { return 0 }

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

            if hasExclusions {
                let canonicalPath = PathExclusionMatcher.canonicalize(url)
                if PathExclusionMatcher.isExcluded(path: canonicalPath, by: canonicalExclusions) {
                    if resourceValues?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
            }

            guard resourceValues?.isRegularFile == true else { continue }

            totalSize += Int64(resourceValues?.fileSize ?? 0)
            progress?()
        }

        return totalSize
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

            if hasExclusions {
                let canonicalRootPath = PathExclusionMatcher.canonicalize(root.url)
                if PathExclusionMatcher.isExcluded(path: canonicalRootPath, by: canonicalExclusions) {
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
                }

                let resourceValues = try? url.resourceValues(forKeys: Self.resourceKeySet)

                if resourceValues?.isSymbolicLink == true {
                    // Skip symlinks unconditionally — this avoids both
                    // double-counting (when the link's target is also under
                    // the scanned root) and pulling in external content
                    // (when the target is outside the root).
                    continue
                }

                // Canonicalize per-file *only* when there are exclusions to
                // compare against — the common case (no exclusions) avoids
                // the extra symlink-resolution work entirely. We can't lift
                // this above the loop because `FileManager.enumerator`
                // doesn't guarantee canonical-prefixed URLs even when given
                // a canonical root, so the comparison has to happen on a
                // resolved path.
                if hasExclusions {
                    let canonicalPath = PathExclusionMatcher.canonicalize(url)
                    if PathExclusionMatcher.isExcluded(path: canonicalPath, by: canonicalExclusions) {
                        if resourceValues?.isDirectory == true {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                }

                let isDirectory = resourceValues?.isDirectory == true
                if options.packagesAsFiles,
                   isDirectory,
                   resourceValues?.isPackage == true {
                    let canonicalPath = PathExclusionMatcher.canonicalize(url)
                    if PathExclusionMatcher.containsExcludedDescendant(
                        of: canonicalPath,
                        in: canonicalExclusions
                    ) {
                        continue
                    }

                    let size = try await PackageDirectorySizer.recursiveSize(
                        of: url,
                        excluding: canonicalExclusions
                    )
                    batch.append(
                        ScannedFile(
                            url: url,
                            size: size,
                            lastAccessDate: resourceValues?.contentAccessDate,
                            lastModifiedDate: resourceValues?.contentModificationDate,
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
    }
}
