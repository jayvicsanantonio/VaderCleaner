// SmartScanByteFormatter.swift
// File-style byte formatting shared by the Applications manager and dashboard so sizes read identically to Finder.

import Foundation

/// File-style byte string ("2.3 GB") matching `ScanResult.formattedTotalSize`,
/// so byte figures read the same way across surfaces and as Finder reports
/// sizes. (Smart Scan itself formats through `CareFindingCopy`.)
///
/// Formats through `ByteCountFormatter`'s type method rather than a shared
/// instance: the class has no documented thread-safety guarantee, and these
/// surfaces format from both the main actor and background scan work. `.file`
/// with default units is the same configuration the shared instance used.
func smartScanFormattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A reusable `ByteCountFormatter` for the surfaces that need a configuration
/// the type method can't express (a restricted `allowedUnits`, a binary count
/// style), guarded so it can be shared safely.
///
/// Thread-safe via a lock (`@unchecked Sendable`, the same discipline as
/// `CleanupManagerStore`): `ByteCountFormatter` carries no documented
/// thread-safety guarantee, and these figures are formatted from both the main
/// actor and background work. The instance is reused rather than rebuilt per
/// call because the hot paths (treemap tiles, menu-bar ticks) format many
/// values per render, and an uncontended lock costs far less than an allocation.
final class LockedByteFormatter: @unchecked Sendable {

    private let lock = NSLock()
    private let formatter: ByteCountFormatter

    init(allowedUnits: ByteCountFormatter.Units, countStyle: ByteCountFormatter.CountStyle, includesUnit: Bool = true) {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = allowedUnits
        formatter.countStyle = countStyle
        formatter.includesUnit = includesUnit
        self.formatter = formatter
    }

    func string(fromByteCount bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(fromByteCount: bytes)
    }
}
