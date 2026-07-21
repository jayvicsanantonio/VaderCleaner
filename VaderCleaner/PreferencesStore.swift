// PreferencesStore.swift
// Observable user-preferences model — defaults, persistence, and dependency-injected UserDefaults for tests.

import Foundation
import Observation

/// How often the "Remind to run regular Smart Care" notification repeats.
enum SmartCareFrequency: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:   return String(localized: "Daily", comment: "Smart Care reminder frequency.")
        case .weekly:  return String(localized: "Weekly", comment: "Smart Care reminder frequency.")
        case .monthly: return String(localized: "Monthly", comment: "Smart Care reminder frequency.")
        }
    }
}

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
        static let diskFreeThresholdGB = "preferences.diskFreeThresholdGB"
        static let launchAtLogin = "preferences.launchAtLogin"
        static let showMenuBar = "preferences.showMenuBar"
        static let menuBarShowsReading = "preferences.menuBarShowsReading"
        // Notifications pane parity (General / Disk Space / Applications).
        static let remindSmartCare = "preferences.remindSmartCare"
        static let smartCareFrequency = "preferences.smartCareFrequency"
        static let notifyScanFinished = "preferences.notifyScanFinished"
        static let notifyTrashSize = "preferences.notifyTrashSize"
        static let trashSizeThresholdGB = "preferences.trashSizeThresholdGB"
        static let notifyDeviceBatteryLow = "preferences.notifyDeviceBatteryLow"
        static let notifyDriveConnected = "preferences.notifyDriveConnected"
        static let notifyOverfilledDrives = "preferences.notifyOverfilledDrives"
        static let offerUninstallOnTrash = "preferences.offerUninstallOnTrash"
        static let notifyHungApps = "preferences.notifyHungApps"
    }

    // MARK: - Defaults

    /// Spec'd defaults from plan.md Prompt 6. Kept on the type so tests and any
    /// future "reset to defaults" UI can reference the same constants.
    static let defaultNotifyLowDisk = true
    static let defaultNotifyHighRAM = true
    static let defaultNotifyMalwareFound = true
    static let defaultNotifyLargeFilesFound = true
    /// Warn when free space drops below this many gigabytes (decimal GB, matching
    /// the Finder-style sizes the rest of the app shows). Replaces the former
    /// percent threshold so the Notifications pane can offer an absolute GB picker.
    static let defaultDiskFreeThresholdGB = 10
    static let defaultLaunchAtLogin = true
    static let defaultShowMenuBar = true
    // Notifications pane parity defaults — every row ships enabled, as in the
    // reference design.
    static let defaultRemindSmartCare = true
    static let defaultSmartCareFrequency = SmartCareFrequency.weekly
    static let defaultNotifyScanFinished = true
    static let defaultNotifyTrashSize = true
    static let defaultTrashSizeThresholdGB = 2
    static let defaultNotifyDeviceBatteryLow = true
    static let defaultNotifyDriveConnected = true
    static let defaultNotifyOverfilledDrives = true
    static let defaultOfferUninstallOnTrash = true
    static let defaultNotifyHungApps = true
    /// Off by default: the menu bar shows just the icon. A wide live reading is
    /// prone to being hidden behind the notch on a crowded menu bar, so showing
    /// it is opt-in.
    static let defaultMenuBarShowsReading = false

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

    /// Warn when free disk space drops below this many gigabytes.
    var diskFreeThresholdGB: Int {
        didSet { defaults.set(diskFreeThresholdGB, forKey: Key.diskFreeThresholdGB) }
    }

    // MARK: Notifications — General

    var remindSmartCare: Bool {
        didSet { defaults.set(remindSmartCare, forKey: Key.remindSmartCare) }
    }

    /// Notify when a scan the user started finishes, naming the section.
    var notifyScanFinished: Bool {
        didSet { defaults.set(notifyScanFinished, forKey: Key.notifyScanFinished) }
    }

    var smartCareFrequency: SmartCareFrequency {
        didSet { defaults.set(smartCareFrequency.rawValue, forKey: Key.smartCareFrequency) }
    }

    var notifyTrashSize: Bool {
        didSet { defaults.set(notifyTrashSize, forKey: Key.notifyTrashSize) }
    }

    var trashSizeThresholdGB: Int {
        didSet { defaults.set(trashSizeThresholdGB, forKey: Key.trashSizeThresholdGB) }
    }

    var notifyDeviceBatteryLow: Bool {
        didSet { defaults.set(notifyDeviceBatteryLow, forKey: Key.notifyDeviceBatteryLow) }
    }

    // MARK: Notifications — Disk Space

    var notifyDriveConnected: Bool {
        didSet { defaults.set(notifyDriveConnected, forKey: Key.notifyDriveConnected) }
    }

    var notifyOverfilledDrives: Bool {
        didSet { defaults.set(notifyOverfilledDrives, forKey: Key.notifyOverfilledDrives) }
    }

    // MARK: Notifications — Applications

    var offerUninstallOnTrash: Bool {
        didSet { defaults.set(offerUninstallOnTrash, forKey: Key.offerUninstallOnTrash) }
    }

    var notifyHungApps: Bool {
        didSet { defaults.set(notifyHungApps, forKey: Key.notifyHungApps) }
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

    /// When on, the menu bar shows a compact free-disk reading next to the icon.
    var menuBarShowsReading: Bool {
        didSet { defaults.set(menuBarShowsReading, forKey: Key.menuBarShowsReading) }
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
        self.diskFreeThresholdGB = (defaults.object(forKey: Key.diskFreeThresholdGB) as? Int)
            ?? Self.defaultDiskFreeThresholdGB
        self.remindSmartCare = (defaults.object(forKey: Key.remindSmartCare) as? Bool)
            ?? Self.defaultRemindSmartCare
        self.notifyScanFinished = (defaults.object(forKey: Key.notifyScanFinished) as? Bool)
            ?? Self.defaultNotifyScanFinished
        self.smartCareFrequency = (defaults.object(forKey: Key.smartCareFrequency) as? String)
            .flatMap(SmartCareFrequency.init(rawValue:)) ?? Self.defaultSmartCareFrequency
        self.notifyTrashSize = (defaults.object(forKey: Key.notifyTrashSize) as? Bool)
            ?? Self.defaultNotifyTrashSize
        self.trashSizeThresholdGB = (defaults.object(forKey: Key.trashSizeThresholdGB) as? Int)
            ?? Self.defaultTrashSizeThresholdGB
        self.notifyDeviceBatteryLow = (defaults.object(forKey: Key.notifyDeviceBatteryLow) as? Bool)
            ?? Self.defaultNotifyDeviceBatteryLow
        self.notifyDriveConnected = (defaults.object(forKey: Key.notifyDriveConnected) as? Bool)
            ?? Self.defaultNotifyDriveConnected
        self.notifyOverfilledDrives = (defaults.object(forKey: Key.notifyOverfilledDrives) as? Bool)
            ?? Self.defaultNotifyOverfilledDrives
        self.offerUninstallOnTrash = (defaults.object(forKey: Key.offerUninstallOnTrash) as? Bool)
            ?? Self.defaultOfferUninstallOnTrash
        self.notifyHungApps = (defaults.object(forKey: Key.notifyHungApps) as? Bool)
            ?? Self.defaultNotifyHungApps
        self.launchAtLogin = (defaults.object(forKey: Key.launchAtLogin) as? Bool)
            ?? Self.defaultLaunchAtLogin
        self.showMenuBar = (defaults.object(forKey: Key.showMenuBar) as? Bool)
            ?? Self.defaultShowMenuBar
        self.menuBarShowsReading = (defaults.object(forKey: Key.menuBarShowsReading) as? Bool)
            ?? Self.defaultMenuBarShowsReading

        // Reconcile the persisted preference with launchd's actual state once
        // the tracked properties are populated. The handler's presence is the
        // signal that we're in production wiring (tests pass nil); skipping in
        // tests keeps unit tests from mutating the host's login items.
        if launchAtLoginHandler != nil {
            applyLaunchAtLogin()
        }
    }

    // MARK: - Restore defaults

    /// Resets every user-tweakable preference to its shipped default. Assigning
    /// through the tracked properties re-runs each `didSet`, so the new values
    /// persist and the launch-at-login change reconciles the login item through
    /// the same handler a manual toggle uses. The Ignore List is deliberately
    /// left untouched — those paths are user data, not a preference.
    func restoreDefaults() {
        notifyLowDisk = Self.defaultNotifyLowDisk
        notifyHighRAM = Self.defaultNotifyHighRAM
        notifyMalwareFound = Self.defaultNotifyMalwareFound
        notifyLargeFilesFound = Self.defaultNotifyLargeFilesFound
        diskFreeThresholdGB = Self.defaultDiskFreeThresholdGB
        remindSmartCare = Self.defaultRemindSmartCare
        notifyScanFinished = Self.defaultNotifyScanFinished
        smartCareFrequency = Self.defaultSmartCareFrequency
        notifyTrashSize = Self.defaultNotifyTrashSize
        trashSizeThresholdGB = Self.defaultTrashSizeThresholdGB
        notifyDeviceBatteryLow = Self.defaultNotifyDeviceBatteryLow
        notifyDriveConnected = Self.defaultNotifyDriveConnected
        notifyOverfilledDrives = Self.defaultNotifyOverfilledDrives
        offerUninstallOnTrash = Self.defaultOfferUninstallOnTrash
        notifyHungApps = Self.defaultNotifyHungApps
        launchAtLogin = Self.defaultLaunchAtLogin
        showMenuBar = Self.defaultShowMenuBar
        menuBarShowsReading = Self.defaultMenuBarShowsReading
    }

    // MARK: - Side effects

    /// Throwing entry point for surfaces that present their own inline failure
    /// (the Performance view's Login Items row). Applies the launch-at-login
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
