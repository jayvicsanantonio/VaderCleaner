// SpaceLensViewMode.swift
// The two Space Lens visualizations (treemap / sunburst) and a small observable store that persists the user's pick through an injected UserDefaults.

import Foundation
import Observation

/// Which visualization Space Lens renders. The sunburst is the default — its
/// concentric rings read disk-usage hierarchy more naturally than nested
/// rectangles; the treemap remains available for users who prefer it.
enum SpaceLensViewMode: String, CaseIterable {
    case treemap
    case sunburst

    /// Toolbar label / accessibility text for the toggle control.
    var displayName: String {
        switch self {
        case .treemap:  return String(localized: "Treemap")
        case .sunburst: return String(localized: "Sunburst")
        }
    }

    /// SF Symbol shown on the toggle button for this mode.
    var symbolName: String {
        switch self {
        case .treemap:  return "square.grid.2x2"
        case .sunburst: return "chart.pie"
        }
    }
}

/// Single source of truth for the Space Lens view-mode preference, backed by
/// `UserDefaults` so the choice survives relaunch.
///
/// Mirrors `PreferencesStore`'s shape: the `UserDefaults` instance is injected
/// so tests can supply an isolated suite instead of touching `.standard`, and
/// production uses the default `.standard` argument. The tracked `mode` is
/// assigned exactly once in `init` (so the `didSet` observer does not fire and
/// rewrite the default on every launch) and persisted on each subsequent
/// change.
@MainActor
@Observable
final class SpaceLensViewModeStore {

    /// Namespaced key so the persisted value can be located by name and never
    /// collides with anything else `.standard` holds.
    private static let key = "spaceLens.viewMode"

    /// The sunburst is the default for fresh installs and any unreadable
    /// persisted value — concentric rings convey hierarchy more naturally.
    static let defaultMode: SpaceLensViewMode = .sunburst

    var mode: SpaceLensViewMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.key) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Single assignment in init skips the `didSet` observer (Swift omits
        // property observers for the first assignment before delegation), so a
        // fresh launch doesn't rewrite the default back to UserDefaults.
        let stored = defaults.string(forKey: Self.key)
        self.mode = stored.flatMap(SpaceLensViewMode.init(rawValue:)) ?? Self.defaultMode
    }
}
