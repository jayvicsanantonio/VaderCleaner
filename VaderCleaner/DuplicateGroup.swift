// DuplicateGroup.swift
// A set of byte-identical files found by DuplicateScanner — one kept original plus the redundant copies that are safe to remove.

import Foundation

/// A group of two or more byte-identical files. `files` is sorted so the first
/// entry is the **kept original** (the most canonical path) and the rest are
/// **redundant copies** the user can remove while always retaining one copy.
struct DuplicateGroup: Identifiable, Equatable, Hashable {

    /// The identical files, sorted with the kept original first.
    let files: [ScannedFile]

    /// Stable identity for SwiftUI lists — the kept original's path.
    var id: String { files.first?.url.path ?? "" }

    /// The copy that is retained and never offered for deletion.
    var original: ScannedFile { files[0] }

    /// Every copy beyond the original — the deletion candidates.
    var redundantCopies: [ScannedFile] { Array(files.dropFirst()) }

    /// Bytes freed if every redundant copy is removed (the original stays).
    var reclaimableBytes: Int64 { redundantCopies.reduce(0) { $0 + $1.size } }
}
