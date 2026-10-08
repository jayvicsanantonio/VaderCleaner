// PathSizer.swift
// The one recursive byte-size walk every scanner shares, so the same folder can never report two different sizes on two different screens.

import Foundation

/// Recursive byte size of a file or directory tree.
///
/// This exists because six scanners had each grown their own copy of this
/// walk and the copies had drifted. The divergence that mattered was
/// `.skipsHiddenFiles`: most passed it, `AppLeftoverScanner` did not, and both
/// measure the same `~/Library` roots — so one folder reported two sizes
/// depending on which screen you were looking at.
///
/// The policy here is chosen to match what deletion actually does:
///
/// - **Hidden entries count.** Removing a folder removes its dotfiles too, so
///   skipping them understates what the user reclaims. On a real
///   `~/Library/Application Support` entry that gap measured 17%.
/// - **Only regular files count.** A symlink's bytes belong to its target,
///   which is either counted elsewhere in the walk or outside the tree
///   entirely; counting it would double-count or import foreign bytes.
/// - **Symlinked directories are never followed**, so a link can't walk the
///   sum clean out of the tree being measured.
/// - **Errors are tolerated.** A permission failure on one nested resource —
///   a sandboxed `XPCService`, say — must not zero the whole row.
///
/// Sizes are logical (`fileSize`), not allocated-on-disk. That is what every
/// caller displayed before this type existed, and it is the number that
/// matches what a copy of the data would occupy.
enum PathSizer {

    /// Byte size of `url`: its own size if it is a regular file, the sum of
    /// its regular-file descendants if it is a directory, and `0` for anything
    /// missing, unreadable, or symlinked.
    static func size(at url: URL, fileManager: FileManager) -> Int64 {
        walk(at: url, fileManager: fileManager, checkpoint: {})
    }

    /// The same walk, interruptible. `checkpoint` runs once per directory
    /// entry, so passing `Task.checkCancellation` aborts partway through a
    /// large tree rather than only between top-level paths.
    ///
    /// A separate overload rather than a defaulted parameter: `rethrows` does
    /// not see through a default argument, which would force every caller to
    /// write `try` for a closure that cannot throw.
    static func size(
        at url: URL,
        fileManager: FileManager,
        checkpoint: () throws -> Void
    ) rethrows -> Int64 {
        try walk(at: url, fileManager: fileManager, checkpoint: checkpoint)
    }

    private static func walk(
        at url: URL,
        fileManager: FileManager,
        checkpoint: () throws -> Void
    ) rethrows -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        try checkpoint()
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }

        if values.isDirectory == true {
            return try directorySize(
                at: url, keys: keys, fileManager: fileManager, checkpoint: checkpoint
            )
        }
        guard values.isRegularFile == true else { return 0 }
        return Int64(values.fileSize ?? 0)
    }

    private static func directorySize(
        at url: URL,
        keys: Set<URLResourceKey>,
        fileManager: FileManager,
        checkpoint: () throws -> Void
    ) rethrows -> Int64 {
        // No `.skipsHiddenFiles`: see the policy note on the type. The error
        // handler returns `true` so an unreadable subtree is stepped over
        // rather than ending the walk.
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            try checkpoint()
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
