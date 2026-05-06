// ScannedFile.swift
// Value type carrying the URL, byte count, dates, and category for a single file the scanner emitted.

import Foundation

/// One record produced by `FileScanner` for a single regular file. Pure data —
/// no I/O happens on this type. The `category` is assigned at scan time based
/// on which `ScanRoot` the file lived under.
///
/// `Equatable` and `Hashable` are derived so test fixtures can compare results
/// directly and view models can use `Set<ScannedFile>` for selection state.
struct ScannedFile: Equatable, Hashable {
    let url: URL
    let size: Int64
    let lastAccessDate: Date
    let lastModifiedDate: Date
    let category: ScanCategory
}
