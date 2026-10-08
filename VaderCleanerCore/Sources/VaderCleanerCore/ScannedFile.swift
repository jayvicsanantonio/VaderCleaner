// ScannedFile.swift
// Value type carrying the URL, byte count, dates, and category for a single file the scanner emitted.

import Foundation

/// One record produced by `FileScanner` for a single regular file. Pure data —
/// no I/O happens on this type. The `category` is assigned at scan time based
/// on which `ScanRoot` the file lived under.
///
/// `lastAccessDate` and `lastModifiedDate` are optional: the file system can
/// legitimately omit either when a volume doesn't track that timestamp, and
/// substituting a sentinel like `.distantPast` would misclassify those files
/// as ancient in the Large & Old Files scanner. `nil` means "unknown — don't
/// classify by age."
///
/// `Equatable` and `Hashable` are derived so test fixtures can compare results
/// directly and view models can use `Set<ScannedFile>` for selection state.
public struct ScannedFile: Equatable, Hashable, Sendable {
    public let url: URL
    public let size: Int64
    public let lastAccessDate: Date?
    public let lastModifiedDate: Date?
    public let category: ScanCategory

    /// The memberwise initializer, written out because Swift only synthesizes
    /// an internal one and the app builds these across the module boundary.
    public init(url: URL, size: Int64, lastAccessDate: Date?, lastModifiedDate: Date?, category: ScanCategory) {
        self.url = url
        self.size = size
        self.lastAccessDate = lastAccessDate
        self.lastModifiedDate = lastModifiedDate
        self.category = category
    }
}

extension ScannedFile: Identifiable {
    public var id: URL { url }
}
