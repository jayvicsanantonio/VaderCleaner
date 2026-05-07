// DiskScanner.swift
// Recursive disk-tree builder for Space Lens — enumerates a root URL into a DiskNode graph, skips symlinks to avoid cycles, and tolerates permission-denied subdirectories.

import Foundation
import os.log

/// Protocol surface mostly here for symmetry with `FileScanning`; tests
/// drive the concrete struct directly via real temp directories rather
/// than through a fake. Listed so future features (Smart Scan, etc.) can
/// substitute their own walker if needed.
protocol DiskScanning {
    func scan(root: URL, progress: @escaping (Int) -> Void) async throws -> DiskNode
}

/// Walks a root URL recursively and returns a `DiskNode` graph whose
/// directory sizes are bottom-up rollups of every regular file underneath.
///
/// Built on `FileManager.contentsOfDirectory(at:...)` rather than
/// `FileManager.enumerator(at:...)` so we can preserve parent → child
/// structure (the enumerator returns descendants flat, which is wrong
/// shape for a treemap) and so we can trap permission errors per
/// directory instead of for the whole walk.
///
/// **Symlink policy** — symlinks are skipped entirely, both file and
/// directory. Dropping directory symlinks is the only reliable way to
/// avoid cycles (a single `~/Library` link loop would otherwise spin
/// forever). Dropping file symlinks is a deliberate consequence of the
/// same uniform rule: counting them would either double-count (when the
/// target lives under the same root) or pull external bytes into the
/// volume's "used space" picture (when it lives outside). Space Lens is
/// asked "where on this volume are the bytes" — the unique on-disk
/// content is the right answer.
///
/// **Progress** — the callback fires once per regular file processed,
/// with the running total. The view-model layer is responsible for
/// translating the count into a 0–1 progress bar; the scanner doesn't
/// know how many files exist up front (an upfront enumeration pass would
/// double the wall-clock cost of every scan).
struct DiskScanner: DiskScanning {

    private static let log = Logger(
        subsystem: "com.personal.VaderCleaner",
        category: "DiskScanner"
    )

    /// Resource keys we ask `URL.resourceValues(forKeys:)` to populate.
    /// We use logical `.fileSizeKey` rather than allocated size: allocated
    /// size rounds every file up to the volume block (4 KB on APFS), which
    /// would cause the treemap to over-report directories full of small
    /// files. Finder's "Get Info" shows logical size for the same reason —
    /// matching that mental model is more important here than reporting
    /// the exact byte count the volume loses to each file.
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .nameKey
    ]

    private static let resourceKeySet = Set(resourceKeys)

    func scan(root: URL, progress: @escaping (Int) -> Void) async throws -> DiskNode {
        var fileCounter = 0
        return try Self.buildNode(
            at: root,
            counter: &fileCounter,
            progress: progress
        )
    }

    /// Recursive builder. Returns the node for `url`, having recursed into
    /// every accessible child. Permission errors on the `contentsOfDirectory`
    /// call surface as an inaccessible node so the rest of the walk
    /// continues; per-file metadata errors fall back to zero size.
    ///
    /// Iterative cancellation check: `Task.checkCancellation()` runs at
    /// every directory boundary. A user kicking off a fresh scan while
    /// one is in flight cancels the parent task — without this, the old
    /// scan would keep churning until the volume was fully walked.
    private static func buildNode(
        at url: URL,
        counter: inout Int,
        progress: @escaping (Int) -> Void
    ) throws -> DiskNode {
        try Task.checkCancellation()

        let resourceValues = try? url.resourceValues(forKeys: resourceKeySet)
        let name = resourceValues?.name ?? url.lastPathComponent
        let isSymlink = resourceValues?.isSymbolicLink ?? false

        // The recursion entry point should never receive a symlink — the
        // parent loop filters them. Defensively short-circuit anyway so a
        // future caller can't accidentally start a scan at a link.
        if isSymlink {
            return DiskNode(
                url: url,
                name: name,
                size: 0,
                isDirectory: false,
                children: [],
                isAccessible: true
            )
        }

        let isDirectory = resourceValues?.isDirectory ?? false

        if !isDirectory {
            // Regular file: logical byte count (see `resourceKeys`
            // comment) and a single progress tick.
            let bytes = Int64(resourceValues?.fileSize ?? 0)
            counter += 1
            progress(counter)
            return DiskNode(
                url: url,
                name: name,
                size: bytes,
                isDirectory: false,
                children: [],
                isAccessible: true
            )
        }

        // Directory — list its contents; if that throws, surface as
        // inaccessible and let the parent walk continue.
        let entries: [URL]
        do {
            // No skip flags: dot-prefixed caches and config dirs are part
            // of the volume's used space and must show up in the treemap.
            entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: []
            )
        } catch {
            log.debug(
                "Skipping unreadable directory \(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
            )
            return DiskNode(
                url: url,
                name: name,
                size: 0,
                isDirectory: true,
                children: [],
                isAccessible: false
            )
        }

        var children: [DiskNode] = []
        children.reserveCapacity(entries.count)
        var rolledUpSize: Int64 = 0

        for entry in entries {
            let entryValues = try? entry.resourceValues(forKeys: resourceKeySet)
            if entryValues?.isSymbolicLink == true {
                // Symlinks are skipped wholesale — see the top-of-file
                // policy note.
                continue
            }
            let child = try buildNode(at: entry, counter: &counter, progress: progress)
            rolledUpSize += child.size
            children.append(child)
        }

        return DiskNode(
            url: url,
            name: name,
            size: rolledUpSize,
            isDirectory: true,
            children: children,
            isAccessible: true
        )
    }
}
