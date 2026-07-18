// CareScanUnit.swift
// The independently-runnable Smart Scan sub-scans and the user-facing domains that group them for settings and the scanning checklist.

import Foundation

/// One independently-runnable Smart Scan sub-scan. Each unit maps to exactly
/// one scanner/service call in `CareScanEngine`; the engine runs them
/// concurrently and reports a per-unit outcome so the results feed can say
/// honestly what was and wasn't checked.
///
/// Raw values are stable persistence/telemetry keys — append new cases, never
/// rename or reorder existing ones.
enum CareScanUnit: String, CaseIterable, Hashable, Sendable {
    case systemJunk
    case duplicates
    case largeOldFiles
    case malware
    case appUpdates
    case unusedApps
    case appLeftovers
    case installers
    case loginItems
    case maintenanceDue
    case browserPrivacy
    case healthSnapshot

    /// The settings/checklist domain this unit belongs to, or `nil` for the
    /// health telemetry snapshot — it is instant, non-destructive, and always
    /// runs, so it never appears as a toggle or a checklist row.
    var domain: CareDomain? {
        switch self {
        case .systemJunk:
            return .systemJunk
        case .duplicates, .largeOldFiles:
            return .myClutter
        case .malware:
            return .malware
        case .appUpdates, .unusedApps, .appLeftovers, .installers:
            return .applications
        case .loginItems, .maintenanceDue:
            return .performance
        case .browserPrivacy:
            return .browserPrivacy
        case .healthSnapshot:
            return nil
        }
    }
}

/// The user-facing grouping of scan units shown in the "Customize Smart Care"
/// settings tree and as the rows of the scanning checklist. Declaration order
/// is display order.
///
/// Raw values reuse the module keys earlier builds persisted in
/// `SmartScanSettingsStore` (`systemJunk`, `myClutter`, `malware`,
/// `applications`, `performance`), so stored preferences keep decoding;
/// `browserPrivacy` is the one addition.
enum CareDomain: String, CaseIterable, Hashable, Sendable {
    case systemJunk
    case myClutter
    case malware
    case browserPrivacy
    case applications
    case performance

    /// The scan units this domain owns, in `CareScanUnit` declaration order.
    var units: [CareScanUnit] {
        CareScanUnit.allCases.filter { $0.domain == self }
    }

    /// User-facing name, matching the sidebar title of the section that owns
    /// the same ground (Cleanup, My Clutter, Protection, …).
    var title: String {
        switch self {
        case .systemJunk:
            return String(localized: "Cleanup", comment: "Smart Scan domain title for system junk.")
        case .myClutter:
            return String(localized: "My Clutter", comment: "Smart Scan domain title for duplicates and large/old files.")
        case .malware:
            return String(localized: "Protection", comment: "Smart Scan domain title for the malware check.")
        case .browserPrivacy:
            return String(localized: "Browser Privacy", comment: "Smart Scan domain title for browsing-data counts.")
        case .applications:
            return String(localized: "Applications", comment: "Smart Scan domain title for app health checks.")
        case .performance:
            return String(localized: "Performance", comment: "Smart Scan domain title for tune-up checks.")
        }
    }
}
