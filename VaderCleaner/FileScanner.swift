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
/// Concrete implementation is `FileScanner` below.
protocol FileScanning {
    func scan(roots: [ScanRoot], excluding: [URL]) async throws -> [ScannedFile]
}

/// Walks each root recursively and returns every regular file as a
/// `ScannedFile` tagged with the root's category. Symlinks are skipped
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

    func scan(roots: [ScanRoot], excluding: [URL]) async throws -> [ScannedFile] {
        let canonicalExclusions = excluding.map(Self.canonicalize)
        var results: [ScannedFile] = []

        for root in roots {
            let rootCanonical = Self.canonicalize(root.url)
            if Self.isExcluded(path: rootCanonical, by: canonicalExclusions) {
                continue
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
                        "Skipping unreadable path \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    return true
                }
            )

            guard let enumerator else { continue }

            for case let url as URL in enumerator {
                let resourceValues = try? url.resourceValues(forKeys: Set(Self.resourceKeys))

                if resourceValues?.isSymbolicLink == true {
                    // Skip symlinks unconditionally — this avoids both
                    // double-counting (when the link's target is also under
                    // the scanned root) and pulling in external content
                    // (when the target is outside the root).
                    continue
                }

                let canonicalPath = Self.canonicalize(url)
                if Self.isExcluded(path: canonicalPath, by: canonicalExclusions) {
                    if resourceValues?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard resourceValues?.isRegularFile == true else { continue }

                let size = Int64(resourceValues?.fileSize ?? 0)
                let accessed = resourceValues?.contentAccessDate ?? .distantPast
                let modified = resourceValues?.contentModificationDate ?? .distantPast

                results.append(
                    ScannedFile(
                        url: url,
                        size: size,
                        lastAccessDate: accessed,
                        lastModifiedDate: modified,
                        category: root.category
                    )
                )
            }
        }

        return results
    }

    // MARK: - Path helpers

    /// Resolves symlinks and normalises `..`/`.` so exclusion comparisons are
    /// done on canonical paths. Mirrors `ExclusionsStore.canonicalize` so a
    /// path the user excluded matches the same canonical form a scanner sees.
    private static func canonicalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// True when `path` is exactly an excluded path or sits beneath one.
    /// Comparison is at path-component boundaries (not raw prefix) so
    /// excluding `/tmp/foo` does not also exclude `/tmp/foobar`. macOS's
    /// default APFS is case-insensitive, hence the case-insensitive compare.
    private static func isExcluded(path: String, by exclusions: [String]) -> Bool {
        for excluded in exclusions {
            if path.caseInsensitiveCompare(excluded) == .orderedSame {
                return true
            }
            let prefix = excluded.hasSuffix("/") ? excluded : excluded + "/"
            if path.lowercased().hasPrefix(prefix.lowercased()) {
                return true
            }
        }
        return false
    }
}
