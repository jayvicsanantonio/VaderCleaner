// DocumentVersionsStoreScan.swift
// Bounded enumeration of the root-owned Document Versions store, shared so the helper and the test suite walk it by the same rules.

import Foundation

/// Lists the regular files inside the Document Versions store.
///
/// This lives in `Shared/` for the same reason `HelperDeletionPolicy` does:
/// the walk itself only ever runs as root inside the helper, where no test
/// can reach it, so the rules it enforces are kept somewhere the suite can
/// drive against a real directory.
struct DocumentVersionsStoreScan {

    /// Most files reported in a single scan.
    ///
    /// The result crosses XPC as two parallel arrays in one message, built
    /// whole in memory on both sides, so an unbounded walk turns a
    /// pathological store into a multi-hundred-megabyte message. Truncating
    /// understates the reclaimable total, which is the milder failure of the
    /// two: the card still offers six figures of files to clean, where the
    /// alternative is a scan that takes the app down with it.
    static let defaultLimit = 100_000

    let limit: Int

    init(limit: Int = DocumentVersionsStoreScan.defaultLimit) {
        self.limit = limit
    }

    /// Parallel arrays of absolute path and byte size for each regular file
    /// under `root`, stopping once `limit` files have been collected.
    ///
    /// Symlinks are skipped so a link inside the store can't pull in content
    /// from outside it or double-count, mirroring the in-process
    /// `FileScanner`. Returns `nil` when `root` can't be enumerated at all,
    /// which the caller reports as an error rather than an empty store.
    func entries(at root: URL) -> (paths: [String], sizes: [NSNumber])? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var paths: [String] = []
        var sizes: [NSNumber] = []
        let keySet = Set(keys)
        while paths.count < limit, let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: keySet)
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            paths.append(url.path)
            sizes.append(NSNumber(value: Int64(values?.fileSize ?? 0)))
        }
        return (paths, sizes)
    }
}
