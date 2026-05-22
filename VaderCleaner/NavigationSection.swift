// NavigationSection.swift
// Defines the sidebar navigation sections for the VaderCleaner app.

import Foundation

enum NavigationSection: CaseIterable, Hashable, Identifiable {
    case smartScan
    case systemJunk
    case largeOldFiles
    case spaceLens
    case malwareRemoval
    case optimization
    case privacy
    case extensions
    case appUninstaller
    case appUpdater
    case healthMonitor

    var id: Self { self }

    var title: String {
        switch self {
        case .smartScan:       return String(localized: "Smart Scan")
        case .systemJunk:      return String(localized: "System Junk")
        case .largeOldFiles:   return String(localized: "Large & Old Files")
        case .spaceLens:       return String(localized: "Space Lens")
        case .malwareRemoval:  return String(localized: "Malware Removal")
        case .optimization:    return String(localized: "Optimization")
        case .privacy:         return String(localized: "Privacy")
        case .extensions:      return String(localized: "Extensions")
        case .appUninstaller:  return String(localized: "App Uninstaller")
        case .appUpdater:      return String(localized: "App Updater")
        case .healthMonitor:   return String(localized: "Health Monitor")
        }
    }

    /// Stable automation identifier for this section's sidebar row. The rail
    /// renders icons only, so UI tests and assistive technology can't rely on
    /// a visible text label — they target this identifier instead. Pinned by
    /// `NavigationSectionTests` so the contract can't drift.
    var accessibilityIdentifier: String {
        switch self {
        case .smartScan:       return "sidebar.smartScan"
        case .systemJunk:      return "sidebar.systemJunk"
        case .largeOldFiles:   return "sidebar.largeOldFiles"
        case .spaceLens:       return "sidebar.spaceLens"
        case .malwareRemoval:  return "sidebar.malwareRemoval"
        case .optimization:    return "sidebar.optimization"
        case .privacy:         return "sidebar.privacy"
        case .extensions:      return "sidebar.extensions"
        case .appUninstaller:  return "sidebar.appUninstaller"
        case .appUpdater:      return "sidebar.appUpdater"
        case .healthMonitor:   return "sidebar.healthMonitor"
        }
    }

    /// Stable automation identifier for this section's floating Scan button.
    /// Built from the enum case name so it shares a recognizable stem with the
    /// `accessibilityIdentifier` suffix (`sidebar.systemJunk` ↔
    /// `section.systemJunk.scan`) without depending on that string's format.
    /// `String(describing:)` on a no-payload case yields the case name and is
    /// the same locale-independent source `SectionIntroView` already uses.
    /// Only scannable sections render this button, but it is defined for every
    /// case so the contract is uniform. Pinned by `NavigationSectionTests`;
    /// the scan-centric UI tests target this identifier.
    var scanAccessibilityIdentifier: String {
        "section.\(String(describing: self)).scan"
    }

    var icon: String {
        switch self {
        case .smartScan:       return "sparkles"
        case .systemJunk:      return "trash"
        case .largeOldFiles:   return "doc.text.magnifyingglass"
        case .spaceLens:       return "square.split.2x2"
        case .malwareRemoval:  return "shield.lefthalf.filled"
        case .optimization:    return "gauge.with.needle"
        case .privacy:         return "lock.shield"
        case .extensions:      return "puzzlepiece.extension"
        case .appUninstaller:  return "xmark.app"
        case .appUpdater:      return "arrow.triangle.2.circlepath.circle"
        case .healthMonitor:   return "heart.text.square"
        }
    }

    /// Whether this section drives a scan/load and therefore adopts the
    /// unified intro screen + floating Scan button. The remaining sections
    /// (live stats and list-style management screens) keep their bespoke UI.
    /// Exhaustive switch with no `default` so a future section is a
    /// compile-time prompt to classify it here.
    var isScannable: Bool {
        switch self {
        case .smartScan, .systemJunk, .largeOldFiles,
             .spaceLens, .malwareRemoval, .optimization, .privacy:
            return true
        case .extensions, .appUninstaller,
             .appUpdater, .healthMonitor:
            return false
        }
    }

    /// Whether this section's scan reads paths that are gated by Full Disk
    /// Access. Drives whether the intro screen shows the inline FDA reminder
    /// card — sections that don't touch FDA-protected paths (Optimization, the
    /// management screens) intentionally never warn so the prompt is reserved
    /// for cases where missing the permission really would yield empty or
    /// incomplete results. Exhaustive switch so a future section is a
    /// compile-time prompt to classify it here.
    var requiresFullDiskAccess: Bool {
        switch self {
        case .smartScan, .systemJunk, .largeOldFiles,
             .spaceLens, .malwareRemoval, .privacy:
            return true
        case .optimization, .extensions,
             .appUninstaller, .appUpdater, .healthMonitor:
            return false
        }
    }
}

/// Which way the detail pane's content travels during a section change —
/// derived from the rail order of the outgoing and incoming sections.
enum SectionTransitionDirection {
    case up
    case down
}

extension NavigationSection {
    /// The direction the main detail content should travel when the rail
    /// selection moves from this section to `target`, decided by their order
    /// in `allCases` (the rail's top-to-bottom order). A move to a lower row
    /// travels `.down`; a move to a higher row travels `.up`.
    func transitionDirection(to target: NavigationSection) -> SectionTransitionDirection {
        let order = NavigationSection.allCases
        guard
            let fromIndex = order.firstIndex(of: self),
            let toIndex = order.firstIndex(of: target)
        else { return .down }
        return toIndex > fromIndex ? .down : .up
    }
}
