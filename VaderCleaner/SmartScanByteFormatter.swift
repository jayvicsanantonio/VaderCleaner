// SmartScanByteFormatter.swift
// File-style byte formatter shared by the Applications manager and dashboard so sizes read identically to Finder.

import Foundation

/// File-style byte formatter matching `ScanResult.formattedTotalSize`, so
/// byte figures read the same way across surfaces and as Finder reports
/// sizes. (Smart Scan itself now formats through `CareFindingCopy`.)
let smartScanByteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.allowedUnits = .useAll
    f.countStyle = .file
    return f
}()
