// SimilarImageGroup.swift
// A cluster of visually near-identical images found by SimilarImageScanner — one kept original plus the redundant near-duplicates that are safe to remove.

import Foundation

/// A group of two or more visually similar images. `files` is ordered so the
/// first entry is the **kept original** (the largest file, i.e. the highest-
/// fidelity copy) and the rest are **redundant near-duplicates** the user can
/// remove while always retaining one. Mirrors `DuplicateGroup`'s shape so both
/// can drive the same review UI.
public struct SimilarImageGroup: Identifiable, Equatable, Hashable, Sendable {

    /// The similar images, ordered with the kept original first.
    public let files: [ScannedFile]

    /// Stable identity for SwiftUI lists — the kept original's path.
    public var id: String { files.first?.url.path ?? "" }

    /// The copy that is retained and never offered for deletion.
    public var original: ScannedFile { files[0] }

    /// Every image beyond the original — the deletion candidates.
    public var redundantCopies: [ScannedFile] { Array(files.dropFirst()) }

    /// Bytes freed if every redundant near-duplicate is removed.
    public var reclaimableBytes: Int64 { redundantCopies.reduce(0) { $0 + $1.size } }
}
