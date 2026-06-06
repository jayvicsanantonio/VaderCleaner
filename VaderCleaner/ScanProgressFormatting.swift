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
        // Pick a singular template at count == 1 — Privacy and the early
        // ticks of any scan can land there — so the readout never says
        // "Scanned 1 items…".
        let template = count == 1
            ? String(
                localized: "Scanned %@ item…",
                comment: "Live progress line, singular, shown while an open-ended scan walks the file system; %@ is a localized item count of one."
            )
            : String(
                localized: "Scanned %@ items…",
                comment: "Live progress line shown while an open-ended scan walks the file system; %@ is a localized item count."
            )
        return String.localizedStringWithFormat(template, formatted)
    }

    /// "Scanned 12,431 files…" — the Malware variant, where each counted unit is
    /// a file ClamAV reported on rather than a generic filesystem item.
    static func filesScanned(_ count: Int) -> String {
        let formatted = count.formatted()
        // Malware counts one file per ClamAV line, so the very first tick is
        // count == 1 — use the singular template there.
        let template = count == 1
            ? String(
                localized: "Scanned %@ file…",
                comment: "Live progress line, singular, shown while the malware scanner checks files; %@ is a localized file count of one."
            )
            : String(
                localized: "Scanned %@ files…",
                comment: "Live progress line shown while the malware scanner checks files; %@ is a localized file count."
            )
        return String.localizedStringWithFormat(template, formatted)
    }
}
