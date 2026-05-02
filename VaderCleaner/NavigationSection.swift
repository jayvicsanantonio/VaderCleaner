// NavigationSection.swift
// Defines the sidebar navigation sections for the VaderCleaner app.

import Foundation

enum NavigationSection: CaseIterable, Hashable, Identifiable {
    case smartScan
    case systemJunk
    case largeOldFiles
    case spaceLens
    case malwareRemoval
    case privacy
    case extensions
    case appUninstaller
    case appUpdater
    case optimization
    case healthMonitor

    var id: Self { self }

    var title: String {
        switch self {
        case .smartScan:       return String(localized: "Smart Scan")
        case .systemJunk:      return String(localized: "System Junk")
        case .largeOldFiles:   return String(localized: "Large & Old Files")
        case .spaceLens:       return String(localized: "Space Lens")
        case .malwareRemoval:  return String(localized: "Malware Removal")
        case .privacy:         return String(localized: "Privacy")
        case .extensions:      return String(localized: "Extensions")
        case .appUninstaller:  return String(localized: "App Uninstaller")
        case .appUpdater:      return String(localized: "App Updater")
        case .optimization:    return String(localized: "Optimization")
        case .healthMonitor:   return String(localized: "Health Monitor")
        }
    }

    var icon: String {
        switch self {
        case .smartScan:       return "sparkles"
        case .systemJunk:      return "trash"
        case .largeOldFiles:   return "doc.text.magnifyingglass"
        case .spaceLens:       return "square.split.2x2"
        case .malwareRemoval:  return "shield.lefthalf.filled"
        case .privacy:         return "lock.shield"
        case .extensions:      return "puzzlepiece.extension"
        case .appUninstaller:  return "xmark.app"
        case .appUpdater:      return "arrow.triangle.2.circlepath.circle"
        case .optimization:    return "gauge.with.needle"
        case .healthMonitor:   return "heart.text.square"
        }
    }
}
