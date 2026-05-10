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
        batchSize: Int,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws
}

extension FileScanning {
    func scan(roots: [ScanRoot], excluding: [URL]) async throws -> [ScannedFile] {
        var results: [ScannedFile] = []
        try await scan(roots: roots, excluding: excluding, batchSize: FileScanner.defaultBatchSize) { batch in
            results.append(contentsOf: batch)
        }
        return results
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
        batchSize: Int = defaultBatchSize,
        onBatch: ([ScannedFile]) async throws -> Void
    ) async throws {
        let batchLimit = max(1, batchSize)
        let canonicalExclusions = excluding.map(Self.canonicalize)
        let hasExclusions = !canonicalExclusions.isEmpty
        var batch: [ScannedFile] = []
        batch.reserveCapacity(batchLimit)
        var visitedCount = 0

        func flushBatch() async throws {
            guard !batch.isEmpty else { return }
            let emitted = batch
            batch.removeAll(keepingCapacity: true)
            try await onBatch(emitted)
            try Task.checkCancellation()
        }

        for root in roots {
            try Task.checkCancellation()

            if hasExclusions {
                let canonicalRootPath = Self.canonicalize(root.url)
                if Self.isExcluded(path: canonicalRootPath, by: canonicalExclusions) {
                    continue
                }
            }

            // `.skipsPackageDescendants` keeps us out of .app bundles and
            // similar packages. `.skipsHiddenFiles` is intentionally NOT
            // set: cache and log directories on macOS routinely contain
            // dot-prefixed files we need to count.
            let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsPackageDescendants],
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
                    let canonicalPath = Self.canonicalize(url)
                    if Self.isExcluded(path: canonicalPath, by: canonicalExclusions) {
                        if resourceValues?.isDirectory == true {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
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

    // MARK: - Path helpers

    /// Resolves symlinks and normalises `..`/`.` so exclusion comparisons are
    /// done on canonical paths. Mirrors `ExclusionsStore.canonicalize` so a
    /// path the user excluded matches the same canonical form a scanner sees.
    private static func canonicalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// True when `path` is exactly an excluded path or sits beneath one.
    /// Comparison is at path-component boundaries (not raw prefix) so
    /// excluding `/tmp/foo` does not also exclude `/tmp/foobar`. macOS's
    /// default APFS is case-insensitive, hence the case-insensitive compare.
    /// Uses `range(of:options:)` rather than `lowercased()` so we don't
    /// allocate a fresh lowercased copy of every enumerated path.
    private static func isExcluded(path: String, by exclusions: [String]) -> Bool {
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
}
