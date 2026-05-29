// ScanProgressFormatting.swift
// Shared, localized copy + number formatting for the live "it's still scanning" feedback shown under each scan's progress indicator.

import Foundation

/// One place for the strings and number formatting the scanning screens use to
/// reassure the user a scan is advancing. Centralised so every section reads
/// identically and locale grouping (`Int.formatted()`) is applied consistently.
enum ScanProgressFormatting {

    /// "Scanned 12,431 items…" — the live walked-count line shown under the
    /// spinner on the open-ended file-walk scans (Large & Old Files, System
    /// Junk, Smart Scan, Privacy). Grouping separators come from the user's
    /// locale via `Int.formatted()`.
    static func itemsScanned(_ count: Int) -> String {
        let formatted = count.formatted()
        let template = String(
            localized: "Scanned %@ items…",
            comment: "Live progress line shown while an open-ended scan walks the file system; %@ is a localized item count."
        )
        return String.localizedStringWithFormat(template, formatted)
    }

    /// "Scanned 12,431 files…" — the Malware variant, where each counted unit is
    /// a file ClamAV reported on rather than a generic filesystem item.
    static func filesScanned(_ count: Int) -> String {
        let formatted = count.formatted()
        let template = String(
            localized: "Scanned %@ files…",
            comment: "Live progress line shown while the malware scanner checks files; %@ is a localized file count."
        )
        return String.localizedStringWithFormat(template, formatted)
    }

    /// "47%" — the determinate variant for Space Lens, whose scan reports a real
    /// completion fraction. `ratio` is clamped to `[0, 1]` so a transient
    /// out-of-range value can't render "−3%" or "120%".
    static func percent(_ ratio: Double) -> String {
        let clamped = max(0.0, min(1.0, ratio))
        return clamped.formatted(.percent.precision(.fractionLength(0)))
    }
}
