// ScanProgressFormatting.swift
// Shared, localized copy + number formatting for the live "it's still scanning" feedback shown under each scan's progress indicator.

import Foundation

/// One place for the strings and number formatting the scanning screens use to
/// reassure the user a scan is advancing. Centralised so every section reads
/// identically and locale grouping (`Int.formatted()`) is applied consistently.
enum ScanProgressFormatting {

    /// "12,431 items" — the live walked-count line shown under the "Scanning…"
    /// label on the open-ended file-walk scans (Large & Old Files, System Junk,
    /// Smart Scan, Privacy). The label already carries the verb, so this line is
    /// just the magnitude — no "Scanned" prefix or trailing ellipsis, which
    /// would double up with the label. Grouping separators come from the user's
    /// locale via `Int.formatted()`.
    static func itemsScanned(_ count: Int) -> String {
        let formatted = count.formatted()
        // Pick a singular template at count == 1 — Privacy and the early
        // ticks of any scan can land there — so the readout never says
        // "1 items".
        let template = count == 1
            ? String(
                localized: "%@ item",
                comment: "Live progress count, singular, shown under the Scanning label while an open-ended scan walks the file system; %@ is a localized item count of one."
            )
            : String(
                localized: "%@ items",
                comment: "Live progress count shown under the Scanning label while an open-ended scan walks the file system; %@ is a localized item count."
            )
        return String.localizedStringWithFormat(template, formatted)
    }

    /// "1,204 checked for threats" — the Smart Scan malware sub-scan's running
    /// files-checked line, phrased with the "for threats" suffix so it reads
    /// distinctly from the generic file-walk "items" count it sits beside.
    static func threatsScanned(_ count: Int) -> String {
        let formatted = count.formatted()
        let template = count == 1
            ? String(
                localized: "%@ checked for threats",
                comment: "Live progress, singular, for the Smart Scan malware sub-scan; %@ is a localized count of one file checked for threats."
            )
            : String(
                localized: "%@ checked for threats",
                comment: "Live progress for the Smart Scan malware sub-scan; %@ is a localized count of files checked for threats."
            )
        return String.localizedStringWithFormat(template, formatted)
    }

    /// "42 of 180 apps checked" — the Smart Scan app-update sub-check's
    /// determinate progress line. The probe knows the total app count up front,
    /// so this reads as bounded progress rather than an open-ended tally.
    static func appsChecked(_ checked: Int, of total: Int) -> String {
        let checkedFormatted = checked.formatted()
        let totalFormatted = total.formatted()
        let template = String(
            localized: "%1$@ of %2$@ apps checked",
            comment: "Live progress for the Smart Scan app-update sub-check; %1$@ is the localized count of apps checked so far, %2$@ the localized total app count."
        )
        return String.localizedStringWithFormat(template, checkedFormatted, totalFormatted)
    }

}
