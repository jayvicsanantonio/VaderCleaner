// SmartScanByteFormatter.swift
// File-style byte formatter shared by the Smart Scan review screens and done summary so freed sizes read identically to Finder.

import Foundation

/// File-style byte formatter matching `ScanResult.formattedTotalSize`, so the
/// "freed" figure on the done screen reads the same way as the size the user
/// saw on the results card and as Finder reports sizes.
let smartScanByteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.allowedUnits = .useAll
    f.countStyle = .file
    return f
}()
