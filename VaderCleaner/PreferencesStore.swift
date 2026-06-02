// PreferencesStore.swift
// Observable user-preferences model — defaults, persistence, and dependency-injected UserDefaults for tests.

import Foundation
import Observation

/// Single source of truth for user-tweakable settings (notifications, disk threshold,
/// launch-at-login, menu bar visibility). Backed by `UserDefaults` so changes survive
/// app relaunch.
///
/// The `UserDefaults` instance is injected so tests can supply an isolated suite
/// instead of touching `.standard`. Production code uses the default `.standard`
/// argument and never sees the seam.
///
/// Side effects that depend on these values are wired in via small handler
/// closures injected at construction. Production wiring happens in
/// `VaderCleanerApp` (e.g. `launchAtLoginHandler` calls `LoginItemManager`);
/// unit tests omit the handlers so mutating a tracked property never
/// triggers a system call. Menu-bar hide/show and notification
/// dispatch follow the same pattern.
@MainActor
@Observable
final class PreferencesStore {

    /// Side-effect contract for the `launchAtLogin` toggle. Production passes
    /// `LoginItemManager.setEnabled`; tests pass `nil` so writing to
    /// `launchAtLogin` is a pure model mutation.
    typealias LaunchAtLoginHandler = @MainActor (Bool) throws -> Void

    /// Reported when applying the launch-at-login change to launchd fails. The
    /// app layer surfaces this via `NSAlert`; the model stays UI-free.
    typealias LaunchAtLoginErrorReporter = @MainActor (Error) -> Void

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

    /// Reads the current `showMenuBar` value out of an arbitrary `UserDefaults`
    /// suite without instantiating the full store. Used by `VaderCleanerAppDelegate`
    /// to decide the activation policy outside of any SwiftUI scene, where
    /// constructing an observation-tracked store would be overkill.
    ///
    /// Marked `nonisolated` because the read touches only the supplied
    /// `UserDefaults` (which is itself thread-safe) and no instance state on
    /// `PreferencesStore` — callers such as `NSWindow.willCloseNotification`
    /// observers run from non-isolated contexts even when their queue is
    /// `.main`.
    nonisolated static func isMenuBarShown(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: Key.showMenuBar) as? Bool) ?? defaultShowMenuBar
    }

    // MARK: - Tracked state

    var notifyLowDisk: Bool {
        didSet { defaults.set(notifyLowDisk, forKey: Key.notifyLowDisk) }
    }

    var notifyHighRAM: Bool {
        didSet { defaults.set(notifyHighRAM, forKey: Key.notifyHighRAM) }
    }

    var notifyMalwareFound: Bool {
        didSet { defaults.set(notifyMalwareFound, forKey: Key.notifyMalwareFound) }
    }

    var notifyLargeFilesFound: Bool {
        didSet { defaults.set(notifyLargeFilesFound, forKey: Key.notifyLargeFilesFound) }
    }

    var diskSpaceThresholdPercent: Double {
        didSet { defaults.set(diskSpaceThresholdPercent, forKey: Key.diskSpaceThresholdPercent) }
    }

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            // The property setter is the Preferences-toggle entry point, which
            // has no inline failure UI, so apply the change and route any
            // failure to the global alert reporter. `setLaunchAtLogin(_:)`
            // applies the side effect itself before updating the tracked value,
            // so it sets `isApplyingLaunchAtLogin` to skip this path and avoid a
            // duplicate SMAppService write (issue #65).
            guard !isApplyingLaunchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }

    var showMenuBar: Bool {
        didSet { defaults.set(showMenuBar, forKey: Key.showMenuBar) }
    }

    // MARK: - Init

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launchAtLoginHandler: LaunchAtLoginHandler?
    @ObservationIgnored private let launchAtLoginErrorReporter: LaunchAtLoginErrorReporter?
    /// Set while `setLaunchAtLogin(_:)` updates the tracked value, so the
    /// property's `didSet` skips re-applying a side effect it has already run.
    @ObservationIgnored private var isApplyingLaunchAtLogin = false

    init(
        defaults: UserDefaults = .standard,
        launchAtLoginHandler: LaunchAtLoginHandler? = nil,
        launchAtLoginErrorReporter: LaunchAtLoginErrorReporter? = nil
    ) {
        self.defaults = defaults
        self.launchAtLoginHandler = launchAtLoginHandler
        self.launchAtLoginErrorReporter = launchAtLoginErrorReporter

        // Assign each property exactly once here so the `didSet` observers
        // above do *not* fire (Swift skips property observers for the first
        // assignment inside an initializer before delegation). Without this
        // discipline every default would be rewritten back to UserDefaults
        // on every launch, defeating the "respect what the user picked"
        // intent of `object(forKey:) as? T`.
        //
        // `UserDefaults.bool(forKey:)` returns `false` for missing keys, but
        // the spec defaults are mostly `true`. Reading via `object(forKey:)
        // as? T` and falling back to the spec default keeps fresh installs
        // aligned with what the user expects.
        self.notifyLowDisk = (defaults.object(forKey: Key.notifyLowDisk) as? Bool)
            ?? Self.defaultNotifyLowDisk
        self.notifyHighRAM = (defaults.object(forKey: Key.notifyHighRAM) as? Bool)
            ?? Self.defaultNotifyHighRAM
        self.notifyMalwareFound = (defaults.object(forKey: Key.notifyMalwareFound) as? Bool)
            ?? Self.defaultNotifyMalwareFound
        self.notifyLargeFilesFound = (defaults.object(forKey: Key.notifyLargeFilesFound) as? Bool)
            ?? Self.defaultNotifyLargeFilesFound
        self.diskSpaceThresholdPercent = (defaults.object(forKey: Key.diskSpaceThresholdPercent) as? Double)
            ?? Self.defaultDiskSpaceThresholdPercent
        self.launchAtLogin = (defaults.object(forKey: Key.launchAtLogin) as? Bool)
            ?? Self.defaultLaunchAtLogin
        self.showMenuBar = (defaults.object(forKey: Key.showMenuBar) as? Bool)
            ?? Self.defaultShowMenuBar

        // Reconcile the persisted preference with launchd's actual state once
        // the tracked properties are populated. The handler's presence is the
        // signal that we're in production wiring (tests pass nil); skipping in
        // tests keeps unit tests from mutating the host's login items.
        if launchAtLoginHandler != nil {
            applyLaunchAtLogin()
        }
    }

    // MARK: - Side effects

    /// Throwing entry point for surfaces that present their own inline failure
    /// (the Optimization view's Login Items row). Applies the launch-at-login
    /// change through the same handler the property setter uses — keeping
    /// `SMAppService` access in one place (issue #65) — but rethrows any failure
    /// to the caller instead of routing it to the global alert reporter, so the
    /// error can be shown inline without double-reporting. On success it updates
    /// and persists the tracked value, keeping the Preferences toggle in lockstep.
    func setLaunchAtLogin(_ enabled: Bool) throws {
        // Apply first so a failure propagates before the model changes. The
        // tracked-value update below would otherwise re-apply via `didSet`, so
        // guard it to keep the handler running exactly once per change.
        if let handler = launchAtLoginHandler {
            try handler(enabled)
        }
        isApplyingLaunchAtLogin = true
        launchAtLogin = enabled
        isApplyingLaunchAtLogin = false
    }

    /// Pushes the current `launchAtLogin` value through the injected handler
    /// (in production, `LoginItemManager.setEnabled`). Errors are forwarded to
    /// the optional reporter so the App layer can surface an alert without
    /// coupling the model to AppKit.
    private func applyLaunchAtLogin() {
        guard let handler = launchAtLoginHandler else { return }
        do {
            try handler(launchAtLogin)
        } catch {
            launchAtLoginErrorReporter?(error)
        }
    }
}
