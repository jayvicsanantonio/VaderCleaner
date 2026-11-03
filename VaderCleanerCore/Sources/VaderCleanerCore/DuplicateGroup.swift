// DuplicateGroup.swift
// A set of byte-identical files found by DuplicateScanner — one kept original plus the redundant copies that are safe to remove.

import Foundation

/// A group of two or more byte-identical files. `files` is sorted so the first
/// entry is the **kept original** (the most canonical path) and the rest are
/// **redundant copies** the user can remove while always retaining one copy.
public struct DuplicateGroup: Identifiable, Equatable, Hashable, Sendable {

    /// The identical files, sorted with the kept original first.
    public let files: [ScannedFile]

    /// Stable identity for SwiftUI lists — the kept original's path.
    public var id: String { files.first?.url.path ?? "" }

    /// The copy that is retained and never offered for deletion.
    public var original: ScannedFile { files[0] }

    /// Every copy beyond the original — the deletion candidates.
    public var redundantCopies: [ScannedFile] { Array(files.dropFirst()) }

    /// Bytes freed if every redundant copy is removed (the original stays).
    public var reclaimableBytes: Int64 { redundantCopies.reduce(0) { $0 + $1.size } }

    /// Whether this group is still what the scan found: the kept original is on
    /// disk, and nothing in the group has been modified since. A plan can sit on
    /// screen for days, and trashing a "redundant" copy of a file that has since
    /// gone or changed could take the only one. A copy that has gone is fine, since
    /// the original still stands. Compares modification dates rather than re-hashing,
    /// so a Fix doesn't re-read every byte the scan already read. A date missing on
    /// either side fails closed: with nothing to compare, the group can't be shown
    /// to be unchanged.
    func isUnchangedOnDisk() -> Bool {
        guard FileManager.default.fileExists(atPath: original.url.path) else { return false }
        return files.allSatisfy { file in
            guard FileManager.default.fileExists(atPath: file.url.path) else { return true }
            guard let scanned = file.lastModifiedDate,
                  let current = (try? URL(fileURLWithPath: file.url.path)
                      .resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate else { return false }
            return current == scanned
        }
    }
}
