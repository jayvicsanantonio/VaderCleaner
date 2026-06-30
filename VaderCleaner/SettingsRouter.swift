// SettingsRouter.swift
// Shared selection state for the Settings window's tabs, so other surfaces (e.g. the Protection intro's Configure Scan button) can open Settings to a specific tab.

import Foundation
import Observation

/// The tabs of the Settings window, used as the `TabView` selection. Adding a
/// case is a compile-time prompt to give it a `.tag(...)` in `PreferencesView`.
enum SettingsTab: Hashable, CaseIterable {
    case general
    case scanning
    case notifications
    case exclusions
    case menuBar
    case protectionScan
}

/// Drives which Settings tab is shown. Injected into both the main `Window`
/// scene and the `Settings` scene so a button in the window (Configure Scan)
/// can select a tab and then call `openSettings()`. Mirrors the `MenuRouter`
/// deep-link pattern the menu bar already uses.
@MainActor
@Observable
final class SettingsRouter {
    /// The tab the Settings window should display. Defaults to General so the
    /// window opens on its first tab when nothing routed it.
    var selectedTab: SettingsTab = .general
}
