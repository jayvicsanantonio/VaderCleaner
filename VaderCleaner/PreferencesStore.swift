// PreferencesStore.swift
// Observable user-preferences model — defaults, persistence, and dependency-injected UserDefaults for tests.

import Foundation
import Combine

/// Single source of truth for user-tweakable settings (notifications, disk threshold,
/// launch-at-login, menu bar visibility). Backed by `UserDefaults` so changes survive
/// app relaunch.
///
/// The `UserDefaults` instance is injected so tests can supply an isolated suite
/// instead of touching `.standard`. Production code uses the default `.standard`
/// argument and never sees the seam.
///
/// Side effects that depend on these values (the actual SMAppService registration
/// in Prompt 7, the menu bar hide/show in Prompt 10, notification dispatch in
/// Prompt 11) are added by later prompts. This store stays a pure model so tests
/// can run without scheduling any system-level work.
@MainActor
final class PreferencesStore: ObservableObject {

    // MARK: - Storage keys

    /// Centralised key namespace so persisted values can be located by name (e.g.
    /// during migration) without grepping through this file. Strings are namespaced
    /// to avoid colliding with anything else `.standard` might already hold.
    private enum Key {
        static let notifyLowDisk = "preferences.notifyLowDisk"
        static let notifyHighRAM = "preferences.notifyHighRAM"
        static let notifyMalwareFound = "preferences.notifyMalwareFound"
        static let notifyLargeFilesFound = "preferences.notifyLargeFilesFound"
        static let diskSpaceThresholdPercent = "preferences.diskSpaceThresholdPercent"
        static let launchAtLogin = "preferences.launchAtLogin"
        static let showMenuBar = "preferences.showMenuBar"
    }

    // MARK: - Defaults

    /// Spec'd defaults from plan.md Prompt 6. Kept on the type so tests and any
    /// future "reset to defaults" UI can reference the same constants.
    static let defaultNotifyLowDisk = true
    static let defaultNotifyHighRAM = true
    static let defaultNotifyMalwareFound = true
    static let defaultNotifyLargeFilesFound = true
    static let defaultDiskSpaceThresholdPercent = 10.0
    static let defaultLaunchAtLogin = true
    static let defaultShowMenuBar = true

    // MARK: - Published state

    @Published var notifyLowDisk: Bool {
        didSet { defaults.set(notifyLowDisk, forKey: Key.notifyLowDisk) }
    }

    @Published var notifyHighRAM: Bool {
        didSet { defaults.set(notifyHighRAM, forKey: Key.notifyHighRAM) }
    }

    @Published var notifyMalwareFound: Bool {
        didSet { defaults.set(notifyMalwareFound, forKey: Key.notifyMalwareFound) }
    }

    @Published var notifyLargeFilesFound: Bool {
        didSet { defaults.set(notifyLargeFilesFound, forKey: Key.notifyLargeFilesFound) }
    }

    @Published var diskSpaceThresholdPercent: Double {
        didSet { defaults.set(diskSpaceThresholdPercent, forKey: Key.diskSpaceThresholdPercent) }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    @Published var showMenuBar: Bool {
        didSet { defaults.set(showMenuBar, forKey: Key.showMenuBar) }
    }

    // MARK: - Init

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Initialise the @Published wrappers directly with `_property =
        // Published(initialValue:)` instead of `self.property = …`. Going
        // through the synthesized setter would fire `objectWillChange.send()`
        // for every property — and because `MenuBarExtra(isInserted:
        // $preferences.showMenuBar)` subscribes the App body to this store,
        // SwiftUI evaluates `body` while the StateObject is still being
        // initialised on first launch. Publisher notifications inside that
        // window trigger "Publishing changes from within view updates is not
        // allowed" and ultimately hang the UI test runner.
        //
        // Bonus: the `didSet` observers below would otherwise rewrite every
        // default back to UserDefaults on every launch. Direct wrapper
        // initialisation skips them.
        //
        // `UserDefaults.bool(forKey:)` returns `false` for missing keys, but
        // the spec defaults are mostly `true`. Reading via `object(forKey:)
        // as? T` and falling back to the spec default keeps fresh installs
        // aligned with what the user expects.
        self._notifyLowDisk = Published(
            initialValue: (defaults.object(forKey: Key.notifyLowDisk) as? Bool)
                ?? Self.defaultNotifyLowDisk
        )
        self._notifyHighRAM = Published(
            initialValue: (defaults.object(forKey: Key.notifyHighRAM) as? Bool)
                ?? Self.defaultNotifyHighRAM
        )
        self._notifyMalwareFound = Published(
            initialValue: (defaults.object(forKey: Key.notifyMalwareFound) as? Bool)
                ?? Self.defaultNotifyMalwareFound
        )
        self._notifyLargeFilesFound = Published(
            initialValue: (defaults.object(forKey: Key.notifyLargeFilesFound) as? Bool)
                ?? Self.defaultNotifyLargeFilesFound
        )
        self._diskSpaceThresholdPercent = Published(
            initialValue: (defaults.object(forKey: Key.diskSpaceThresholdPercent) as? Double)
                ?? Self.defaultDiskSpaceThresholdPercent
        )
        self._launchAtLogin = Published(
            initialValue: (defaults.object(forKey: Key.launchAtLogin) as? Bool)
                ?? Self.defaultLaunchAtLogin
        )
        self._showMenuBar = Published(
            initialValue: (defaults.object(forKey: Key.showMenuBar) as? Bool)
                ?? Self.defaultShowMenuBar
        )
    }
}
