// SettingsRestore.swift
// Resets every store the Settings window writes to, so Restore Defaults covers the scan-folder scopes as well as the preference stores.

import Foundation

/// The one place that knows the full set of stores "Restore Defaults" has to
/// reach. It exists because the dialog promises "Your settings go back to how
/// they started" while the two scan-folder scopes — both picked inside the
/// Scanning tab — were left untouched, and a list spread across a confirmation
/// dialog's action closure can't be tested.
///
/// The Ignore List is deliberately absent: those paths are user data, not a
/// preference, and the dialog says so.
@MainActor
enum SettingsRestore {

    static func restoreAll(
        preferences: PreferencesStore,
        protection: ProtectionSettingsStore,
        smartScan: SmartScanSettingsStore,
        webDevScanScope: WebDevScanScopeStore,
        myClutterScanScope: MyClutterScanScopeStore
    ) {
        preferences.restoreDefaults()
        protection.restoreDefaults()
        smartScan.restoreDefaults()
        // Each scope store's "back to the default scope" method *is* its reset,
        // so there's no separate defaults to duplicate here.
        webDevScanScope.selectDefault()
        myClutterScanScope.selectHome()
    }
}
