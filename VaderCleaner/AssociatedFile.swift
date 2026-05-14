// AssociatedFile.swift
// Value type representing a single on-disk artifact belonging to an installed app — preferences, caches, logs, container, etc. — that the App Uninstaller surfaces for review and bulk removal.

import Foundation

/// Categories the App Uninstaller groups associated files under in the UI.
///
/// Raw values are stable identifiers used by the view layer for sectioning
/// and accessibility identifiers; do not reorder existing cases or rename
/// raw values without bumping callers.
enum AssociatedFileCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case preferences
    case applicationSupport
    case cache
    case logs
    case containers
    case groupContainers
    case savedState
    case launchAgents
    case launchDaemons

    var id: String { rawValue }

    /// Human-readable section heading. Localised at the call site (the view
    /// layer wraps this through `String(localized:)`) so the stable raw value
    /// remains separate from display copy.
    var displayName: String {
        switch self {
        case .preferences:        return "Preferences"
        case .applicationSupport: return "Application Support"
        case .cache:              return "Caches"
        case .logs:               return "Logs"
        case .containers:         return "Containers"
        case .groupContainers:    return "Group Containers"
        case .savedState:         return "Saved Application State"
        case .launchAgents:       return "Launch Agents"
        case .launchDaemons:      return "Launch Daemons"
        }
    }
}

/// A single on-disk artifact owned by an installed app. The App Uninstaller
/// surfaces these grouped by `category` so the user can review what's about
/// to be moved to Trash alongside the `.app` bundle.
///
/// `Identifiable` by `url` so SwiftUI lists stay stable as a finder pass
/// re-emits the same item — `Hashable` so selection sets and dedup work
/// without needing to introduce a separate identifier strategy.
struct AssociatedFile: Identifiable, Hashable, Sendable {
    let url: URL
    let sizeBytes: Int64
    let category: AssociatedFileCategory

    var id: URL { url }
}
