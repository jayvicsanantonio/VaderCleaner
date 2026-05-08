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

/// Conditions under which a scan can't run at all, as distinct from a
/// per-file/per-dir permission denial inside the walk (which is
/// recovered as an inaccessible `DiskNode`). Surfaced so the view-model
/// can land in `.error` instead of producing a misleading zero-byte
/// tree that looks like a successful empty scan.
enum DiskScanError: LocalizedError, Equatable {
    /// The root URL handed to `scan(root:progress:)` is missing,
    /// unreadable, or on an unmounted volume. The recursive walker
    /// can't recover from this — there's no parent to mark inaccessible.
    case rootInaccessible(URL)

    var errorDescription: String? {
        switch self {
        case .rootInaccessible(let url):
            return "Couldn't read “\(url.lastPathComponent)”. The location may have been moved, deleted, or the volume is unmounted."
        }
    }
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

    /// Reference-typed counter so the recursion can mutate a shared
    /// running total across `await` suspension points. Swift forbids
    /// `inout` parameters across `await`, and a class instance threads
    /// the same value through every recursive call without that
    /// restriction.
    private final class FileCounter {
        var value: Int = 0
    }

    func scan(root: URL, progress: @escaping (Int) -> Void) async throws -> DiskNode {
        // Resolve symlinks at the root only. macOS exposes `/tmp`,
        // `/var`, and `/etc` as symlinks to `/private/...`; if the user
        // picks one as a Space Lens root, the symlink-skip branch
        // inside the walk would hand back a zero-byte "file" node.
        // Inside `buildNode` we still skip symlinks unconditionally
        // (cycle prevention + no double-counting); the asymmetry is
        // deliberate, the root is the one place where there's no
        // parent to omit it from. Errors continue to reference the
        // *original* URL so the user sees the path they actually
        // selected.
        let resolvedRoot = root.resolvingSymlinksInPath()

        // Validate the root up front. Inside `buildNode` we `try?`
        // metadata reads so a single broken descendant doesn't abort
        // the walk — but at the root, the same forgiveness silently
        // emits a zero-byte "file" node and the user sees a
        // successful empty scan. Throw a typed error here so the VM
        // can render `.error` for missing paths and unmounted volumes.
        do {
            _ = try resolvedRoot.resourceValues(forKeys: Self.resourceKeySet)
        } catch {
            throw DiskScanError.rootInaccessible(root)
        }

        let counter = FileCounter()
        return try await Self.buildNode(
            at: resolvedRoot,
            counter: counter,
            progress: progress,
            isRoot: true
        )
    }

    /// Recursive builder. Returns the node for `url`, having recursed into
    /// every accessible child. Permission errors on the `contentsOfDirectory`
    /// call surface as an inaccessible node so the rest of the walk
    /// continues; per-file metadata errors fall back to zero size.
    ///
    /// `isRoot` distinguishes the scan's root call from recursive
    /// descendant calls. Listing failure on a descendant produces an
    /// inaccessible node (the parent shows it as a locked child);
    /// listing failure on the root has nowhere to render — the scan
    /// would otherwise quietly succeed with a zero-byte tree — so it's
    /// rethrown as `DiskScanError.rootInaccessible` for the VM to
    /// route to `.error`.
    ///
    /// Iterative cancellation + cooperative yield at every directory
    /// boundary: `Task.checkCancellation()` lets a freshly-started scan
    /// abort an older one immediately, and `await Task.yield()`
    /// surrenders the cooperative thread so a multi-million-file walk
    /// doesn't hold one thread off the pool for the whole scan. The
    /// yield runs *after* the cancellation check so a cancelled task
    /// throws right away instead of giving the queue a chance to run
    /// other ready work first.
    private static func buildNode(
        at url: URL,
        counter: FileCounter,
        progress: @escaping (Int) -> Void,
        isRoot: Bool = false
    ) async throws -> DiskNode {
        try Task.checkCancellation()
        await Task.yield()

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
            counter.value += 1
            progress(counter.value)
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
            // Root listing failure: the chmod-000 / protected-folder
            // case Codex flagged. `resourceValues` succeeds via stat
            // through the parent, but the user can't enumerate the
            // contents — so the scan can't actually run. Fail loudly
            // rather than emit a single inaccessible node that the VM
            // would surface as `.ready(emptyTree)`.
            if isRoot {
                throw DiskScanError.rootInaccessible(url)
            }
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
            let child = try await buildNode(at: entry, counter: counter, progress: progress)
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
