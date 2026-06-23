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
    case applications
    case healthMonitor

    var id: Self { self }

    var title: String {
        switch self {
        case .smartScan:       return String(localized: "Smart Scan")
        case .systemJunk:      return String(localized: "Cleanup")
        case .largeOldFiles:   return String(localized: "My Clutter")
        case .spaceLens:       return String(localized: "Space Lens")
        case .malwareRemoval:  return String(localized: "Malware Removal")
        case .optimization:    return String(localized: "Optimization")
        case .privacy:         return String(localized: "Privacy")
        case .applications:    return String(localized: "Applications")
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
        case .applications:    return "sidebar.applications"
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
        case .applications:    return "square.grid.2x2"
        case .healthMonitor:   return "heart.text.square"
        }
    }

    /// Asset-catalog name of this section's monochrome rail glyph — a light
    /// matte relief. The rail renders it neutral when inactive and multiplies
    /// it by `theme.accent` when active. The scannable sections' glyphs are
    /// derived from their hero art by `Scripts/generate-rail-glyphs.swift`;
    /// Health Monitor ships no hero render, so its glyph is authored
    /// procedurally by `Scripts/generate-health-monitor-glyph.swift`.
    var railIconAssetName: String? {
        switch self {
        case .smartScan:       return "smartScanMono"
        case .systemJunk:      return "systemJunkMono"
        case .largeOldFiles:   return "largeOldFilesMono"
        case .spaceLens:       return "spaceLensMono"
        case .malwareRemoval:  return "malwareRemovalMono"
        case .optimization:    return "optimizationMono"
        case .privacy:         return "privacyMono"
        case .applications:    return "applicationsMono"
        case .healthMonitor:   return "healthMonitorMono"
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
             .spaceLens, .malwareRemoval, .optimization, .privacy,
             .applications:
            return true
        case .healthMonitor:
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
        case .optimization,
             .applications, .healthMonitor:
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
    /// in `allCases` (the rail's top-to-bottom order). The motion reads as a
    /// scroll between rows: a move to a lower row scrolls the content `.up`
    /// (outgoing exits the top edge, incoming follows up from the bottom),
    /// and a move to a higher row mirrors it the other way as `.down`.
    func transitionDirection(to target: NavigationSection) -> SectionTransitionDirection {
        let order = NavigationSection.allCases
        guard
            let fromIndex = order.firstIndex(of: self),
            let toIndex = order.firstIndex(of: target)
        else { return .down }
        return toIndex > fromIndex ? .up : .down
    }
}
