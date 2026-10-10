// PreferencesStore.swift
// Observable user-preferences model — defaults, persistence, and dependency-injected UserDefaults for tests.

import Foundation
import Observation
import os.log

/// How often the "Remind me to run a Smart Scan" notification repeats.
public enum SmartCareFrequency: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .daily:   return String(localized: "Daily", bundle: .module, comment: "Smart Scan reminder frequency.")
        case .weekly:  return String(localized: "Weekly", bundle: .module, comment: "Smart Scan reminder frequency.")
        case .monthly: return String(localized: "Monthly", bundle: .module, comment: "Smart Scan reminder frequency.")
        }
    }
}

/// What VaderCleaner shows beside its menu bar icon. Free disk space barely
/// moves between glances, so it is one option rather than the only one; the
/// raw value is the persisted key and must stay stable across releases.
public enum MenuBarReading: String, CaseIterable, Identifiable, Sendable {
    case none
    case freeSpace
    case memory
    case cpu

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none:      return String(localized: "Nothing", bundle: .module, comment: "Menu bar reading choice.")
        case .freeSpace: return String(localized: "Free space", bundle: .module, comment: "Menu bar reading choice.")
        case .memory:    return String(localized: "Memory pressure", bundle: .module, comment: "Menu bar reading choice.")
        case .cpu:       return String(localized: "CPU load", bundle: .module, comment: "Menu bar reading choice.")
        }
    }
}

/// Where VaderCleaner keeps an icon. Modelled as a three-way rather than two
/// switches so "neither" is unreachable — with no menu bar icon and no Dock
/// icon, a user whose window is closed has no way back into the app.
public enum MenuBarPresence: String, CaseIterable, Identifiable, Sendable {
    case menuBarOnly
    case dockOnly
    case both

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .menuBarOnly: return String(localized: "Menu bar", bundle: .module, comment: "Where the app keeps an icon.")
        case .dockOnly:    return String(localized: "Dock", bundle: .module, comment: "Where the app keeps an icon.")
        case .both:        return String(localized: "Both", bundle: .module, comment: "Where the app keeps an icon.")
        }
    }
}

/// A row in the menu bar panel's vitals list. Users can hide the ones they
/// don't care about — Devices is dead weight with nothing connected, and
/// Network needs Location access to name the Wi-Fi network.
public enum MenuBarPanelRow: String, CaseIterable, Identifiable, Sendable {
    case protection
    case storage
    case memory
    case cpu
    case network
    case devices

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .protection: return String(localized: "Protection", bundle: .module, comment: "Menu bar panel row.")
        case .storage:    return String(localized: "Storage", bundle: .module, comment: "Menu bar panel row.")
        case .memory:     return String(localized: "Memory", bundle: .module, comment: "Menu bar panel row.")
        case .cpu:        return String(localized: "CPU", bundle: .module, comment: "Menu bar panel row.")
        case .network:    return String(localized: "Wi-Fi & network", bundle: .module, comment: "Menu bar panel row.")
        case .devices:    return String(localized: "Connected devices", bundle: .module, comment: "Menu bar panel row.")
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
public final class PreferencesStore {

    /// Side-effect contract for the `launchAtLogin` toggle. Production passes
    /// `LoginItemManager.setEnabled`; tests pass `nil` so writing to
    /// `launchAtLogin` is a pure model mutation. `@Sendable` because the store
    /// calls it off the main actor: `SMAppService.register()` and
    /// `unregister()` block until launchd answers.
    public typealias LaunchAtLoginHandler = @Sendable (Bool) throws -> Void

    /// Reported when applying the launch-at-login change to launchd fails. The
    /// app layer surfaces this via `NSAlert`; the model stays UI-free.
    public typealias LaunchAtLoginErrorReporter = @MainActor (Error) -> Void

    /// Side-effect contract for the live-stats cadence. Production pushes the
    /// new value into `SystemStatsService`, which re-arms its timer. Injected
    /// rather than applied by the Menu Bar tab so *every* writer reaches the
    /// service — Restore Defaults fires from the General tab, where that tab's
    /// view (and its `onChange`) is not the one on screen.
    public typealias StatsUpdateIntervalHandler = @MainActor (Double) -> Void

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
        static let notifyAppUpdates = "preferences.notifyAppUpdates"
        static let installUpdatesAutomatically = "preferences.installUpdatesAutomatically"
        static let notifyDefinitionsStale = "preferences.notifyDefinitionsStale"
        static let notificationSoundsEnabled = "preferences.notificationSoundsEnabled"
        static let menuBarReading = "preferences.menuBarReading"
        static let keepDockIcon = "preferences.keepDockIcon"
        static let panelRowStates = "preferences.menuBarPanelRows"
        static let statsUpdateInterval = "preferences.statsUpdateInterval"
    }

    // MARK: - Defaults

    /// The shipping defaults, kept on the type so tests and `restoreDefaults()`
    /// reference the same constants rather than each restating a literal.
    static let defaultNotifyLowDisk = true
    static let defaultNotifyHighRAM = true
    static let defaultNotifyMalwareFound = true
    static let defaultNotifyLargeFilesFound = true
    /// Warn when free space drops below this many gigabytes (decimal GB, matching
    /// the Finder-style sizes the rest of the app shows). Replaces the former
    /// percent threshold so the Notifications pane can offer an absolute GB picker.
    static let defaultDiskFreeThresholdGB = 10
    static let defaultLaunchAtLogin = true
    nonisolated static let defaultShowMenuBar = true
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
    /// Reads a persisted Bool, falling back to its default when the key
    /// has never been written. Collapses what was a repeated two-line
    /// read for each of the many Bool preferences below.
    static func bool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }

    static let defaultNotifyAppUpdates = true
    /// Off by default. Installing replaces an application in place, and a
    /// default that quits the user's app and swaps its bundle is not one
    /// to opt them into — especially before they have watched it work
    /// once. Off means the Updater downloads exactly as it always did.
    static let defaultInstallUpdatesAutomatically = false
    static let defaultNotifyDefinitionsStale = true
    /// On by default: every banner carried an unconditional `.default` sound
    /// before this preference existed, so silence is the new choice rather
    /// than a silently changed default.
    static let defaultNotificationSoundsEnabled = true
    /// Off by default: the menu bar shows just the icon. A wide live reading is
    /// prone to being hidden behind the notch on a crowded menu bar, so showing
    /// it is opt-in.
    static let defaultMenuBarShowsReading = false
    /// Nothing beside the icon by default — a wide label is the thing most
    /// likely to end up hidden behind the notch.
    static let defaultMenuBarReading: MenuBarReading = .none
    /// Off by default, preserving the existing behaviour where the Dock icon
    /// follows the window and the menu bar rather than being pinned.
    nonisolated static let defaultKeepDockIcon = false
    /// Two seconds: live enough for the panel's memory and CPU rows.
    /// `nonisolated` so `statsUpdateInterval(in:)` can read it before the app
    /// has a store — the same treatment the two activation-policy flags get.
    nonisolated static let defaultStatsUpdateInterval: Double = 2

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
    public nonisolated static func isMenuBarShown(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: Key.showMenuBar) as? Bool) ?? defaultShowMenuBar
    }

    /// Companion to `isMenuBarShown(in:)` for the Dock half of the activation
    /// policy, read from the same non-isolated contexts.
    public nonisolated static func isDockIconKept(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: Key.keepDockIcon) as? Bool) ?? defaultKeepDockIcon
    }

    /// Reads the persisted stats cadence without building the store, so
    /// `SystemStatsService` can be constructed first and then handed to the
    /// store as the `statsUpdateIntervalHandler` target.
    public nonisolated static func statsUpdateInterval(in defaults: UserDefaults = .standard) -> Double {
        (defaults.object(forKey: Key.statsUpdateInterval) as? Double) ?? defaultStatsUpdateInterval
    }

    // MARK: - Tracked state

    public var notifyLowDisk: Bool {
        didSet { defaults.set(notifyLowDisk, forKey: Key.notifyLowDisk) }
    }

    public var notifyHighRAM: Bool {
        didSet { defaults.set(notifyHighRAM, forKey: Key.notifyHighRAM) }
    }

    public var notifyMalwareFound: Bool {
        didSet { defaults.set(notifyMalwareFound, forKey: Key.notifyMalwareFound) }
    }

    public var notifyLargeFilesFound: Bool {
        didSet { defaults.set(notifyLargeFilesFound, forKey: Key.notifyLargeFilesFound) }
    }

    /// Warn when free disk space drops below this many gigabytes.
    public var diskFreeThresholdGB: Int {
        didSet { defaults.set(diskFreeThresholdGB, forKey: Key.diskFreeThresholdGB) }
    }

    // MARK: Notifications — General

    public var remindSmartCare: Bool {
        didSet { defaults.set(remindSmartCare, forKey: Key.remindSmartCare) }
    }

    /// Notify when a scan the user started finishes, naming the section.
    public var notifyScanFinished: Bool {
        didSet { defaults.set(notifyScanFinished, forKey: Key.notifyScanFinished) }
    }

    public var smartCareFrequency: SmartCareFrequency {
        didSet { defaults.set(smartCareFrequency.rawValue, forKey: Key.smartCareFrequency) }
    }

    public var notifyTrashSize: Bool {
        didSet { defaults.set(notifyTrashSize, forKey: Key.notifyTrashSize) }
    }

    public var trashSizeThresholdGB: Int {
        didSet { defaults.set(trashSizeThresholdGB, forKey: Key.trashSizeThresholdGB) }
    }

    public var notifyDeviceBatteryLow: Bool {
        didSet { defaults.set(notifyDeviceBatteryLow, forKey: Key.notifyDeviceBatteryLow) }
    }

    // MARK: Notifications — Disk Space

    public var notifyDriveConnected: Bool {
        didSet { defaults.set(notifyDriveConnected, forKey: Key.notifyDriveConnected) }
    }

    public var notifyOverfilledDrives: Bool {
        didSet { defaults.set(notifyOverfilledDrives, forKey: Key.notifyOverfilledDrives) }
    }

    // MARK: Notifications — Applications

    public var offerUninstallOnTrash: Bool {
        didSet { defaults.set(offerUninstallOnTrash, forKey: Key.offerUninstallOnTrash) }
    }

    public var notifyHungApps: Bool {
        didSet { defaults.set(notifyHungApps, forKey: Key.notifyHungApps) }
    }

    /// Notify when newer versions of the user's apps are available. Gates the
    /// background check itself, not just the banner — off means no update
    /// probing happens at all.
    public var notifyAppUpdates: Bool {
        didSet { defaults.set(notifyAppUpdates, forKey: Key.notifyAppUpdates) }
    }

    /// Apply web updates in place — download, verify, swap the bundle,
    /// relaunch — rather than opening the download and leaving the user to
    /// install it by hand.
    ///
    /// Gates the install only. Updates are still found and offered when
    /// this is off; the button just opens the download, which is the
    /// behaviour that predates auto-install.
    public var installUpdatesAutomatically: Bool {
        didSet { defaults.set(installUpdatesAutomatically, forKey: Key.installUpdatesAutomatically) }
    }

    /// Notify when the malware signature database hasn't been refreshed
    /// recently — stale definitions mean quietly weaker protection.
    public var notifyDefinitionsStale: Bool {
        didSet { defaults.set(notifyDefinitionsStale, forKey: Key.notifyDefinitionsStale) }
    }

    // MARK: Notifications — delivery

    /// Whether banners play a sound. Applies to every notification the app
    /// sends; macOS still owns per-app delivery style and Focus.
    public var notificationSoundsEnabled: Bool {
        didSet { defaults.set(notificationSoundsEnabled, forKey: Key.notificationSoundsEnabled) }
    }

    public var launchAtLogin: Bool {
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

    public var showMenuBar: Bool {
        didSet { defaults.set(showMenuBar, forKey: Key.showMenuBar) }
    }

    /// When on, the menu bar shows a compact free-disk reading next to the icon.
    /// Superseded by `menuBarReading`; kept so an existing choice can be
    /// migrated on first launch after the upgrade.
    var menuBarShowsReading: Bool {
        didSet { defaults.set(menuBarShowsReading, forKey: Key.menuBarShowsReading) }
    }

    /// What, if anything, is shown beside the menu bar icon.
    public var menuBarReading: MenuBarReading {
        didSet { defaults.set(menuBarReading.rawValue, forKey: Key.menuBarReading) }
    }

    /// Keeps the Dock icon regardless of whether a window is open. Paired with
    /// `showMenuBar` through `menuBarPresence`, which enforces that at least
    /// one entry point survives.
    var keepDockIcon: Bool {
        didSet { defaults.set(keepDockIcon, forKey: Key.keepDockIcon) }
    }

    /// How often the live stats behind the panel and menu bar refresh. Applied
    /// through the handler as well as persisted, so a new cadence takes effect
    /// immediately whichever surface changed it.
    public var statsUpdateInterval: Double {
        didSet {
            defaults.set(statsUpdateInterval, forKey: Key.statsUpdateInterval)
            statsUpdateIntervalHandler?(statsUpdateInterval)
        }
    }

    /// Which panel rows the user has switched off. Absent means visible, so a
    /// row added in a later release shows up rather than being silently off.
    private var panelRowStates: [String: Bool] {
        didSet { defaults.set(panelRowStates, forKey: Key.panelRowStates) }
    }

    public func isPanelRowEnabled(_ row: MenuBarPanelRow) -> Bool {
        panelRowStates[row.rawValue] ?? true
    }

    public func setPanelRow(_ row: MenuBarPanelRow, enabled: Bool) {
        panelRowStates[row.rawValue] = enabled
    }

    /// Where the app keeps an icon, derived from `showMenuBar` + `keepDockIcon`.
    /// Writing it can never produce "neither", which is what makes this safe to
    /// expose as a picker.
    public var menuBarPresence: MenuBarPresence {
        get {
            switch (showMenuBar, keepDockIcon) {
            case (true, true):  return .both
            case (true, false): return .menuBarOnly
            // Both off shouldn't be reachable through the picker; report
            // Dock-only so a hand-edited defaults file still renders.
            case (false, _):    return .dockOnly
            }
        }
        set {
            switch newValue {
            case .menuBarOnly:
                showMenuBar = true
                keepDockIcon = false
            case .dockOnly:
                showMenuBar = false
                keepDockIcon = true
            case .both:
                showMenuBar = true
                keepDockIcon = true
            }
        }
    }

    // MARK: - Init

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launchAtLoginHandler: LaunchAtLoginHandler?
    @ObservationIgnored private let launchAtLoginErrorReporter: LaunchAtLoginErrorReporter?
    @ObservationIgnored private let statsUpdateIntervalHandler: StatsUpdateIntervalHandler?
    /// Set while `setLaunchAtLogin(_:)` updates the tracked value — and while a
    /// failed apply reverts it — so the property's `didSet` skips re-applying a
    /// side effect it has already run.
    @ObservationIgnored private var isApplyingLaunchAtLogin = false
    /// What launchd last accepted, and so what the toggle goes back to when a
    /// write fails. Seeded with the persisted preference: that is the value
    /// `init`'s reconcile pushes, and a failed reconcile should leave the
    /// stored choice standing rather than invent its opposite.
    @ObservationIgnored private var acceptedLaunchAtLogin: Bool
    /// The newest launch-at-login write. Each write waits for the one before
    /// it, so writes reach launchd one at a time and in the order they were
    /// made.
    @ObservationIgnored private var launchAtLoginWrite: Task<Void, any Error>?
    /// Counts the launch-at-login writes requested so far, so a finished write
    /// can tell whether a newer one has superseded it.
    @ObservationIgnored private var launchAtLoginWriteGeneration = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "PreferencesStore")

    public init(
        defaults: UserDefaults = .standard,
        launchAtLoginHandler: LaunchAtLoginHandler? = nil,
        launchAtLoginErrorReporter: LaunchAtLoginErrorReporter? = nil,
        statsUpdateIntervalHandler: StatsUpdateIntervalHandler? = nil
    ) {
        self.defaults = defaults
        self.launchAtLoginHandler = launchAtLoginHandler
        self.launchAtLoginErrorReporter = launchAtLoginErrorReporter
        self.statsUpdateIntervalHandler = statsUpdateIntervalHandler

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
        self.notifyLowDisk = Self.bool(defaults, Key.notifyLowDisk, default: Self.defaultNotifyLowDisk)
        self.notifyHighRAM = Self.bool(defaults, Key.notifyHighRAM, default: Self.defaultNotifyHighRAM)
        self.notifyMalwareFound = Self.bool(defaults, Key.notifyMalwareFound, default: Self.defaultNotifyMalwareFound)
        self.notifyLargeFilesFound = Self.bool(defaults, Key.notifyLargeFilesFound, default: Self.defaultNotifyLargeFilesFound)
        self.diskFreeThresholdGB = (defaults.object(forKey: Key.diskFreeThresholdGB) as? Int)
            ?? Self.defaultDiskFreeThresholdGB
        self.remindSmartCare = Self.bool(defaults, Key.remindSmartCare, default: Self.defaultRemindSmartCare)
        self.notifyScanFinished = Self.bool(defaults, Key.notifyScanFinished, default: Self.defaultNotifyScanFinished)
        self.smartCareFrequency = (defaults.object(forKey: Key.smartCareFrequency) as? String)
            .flatMap(SmartCareFrequency.init(rawValue:)) ?? Self.defaultSmartCareFrequency
        self.notifyTrashSize = Self.bool(defaults, Key.notifyTrashSize, default: Self.defaultNotifyTrashSize)
        self.trashSizeThresholdGB = (defaults.object(forKey: Key.trashSizeThresholdGB) as? Int)
            ?? Self.defaultTrashSizeThresholdGB
        self.notifyDeviceBatteryLow = Self.bool(defaults, Key.notifyDeviceBatteryLow, default: Self.defaultNotifyDeviceBatteryLow)
        self.notifyDriveConnected = Self.bool(defaults, Key.notifyDriveConnected, default: Self.defaultNotifyDriveConnected)
        self.notifyOverfilledDrives = Self.bool(defaults, Key.notifyOverfilledDrives, default: Self.defaultNotifyOverfilledDrives)
        self.offerUninstallOnTrash = Self.bool(defaults, Key.offerUninstallOnTrash, default: Self.defaultOfferUninstallOnTrash)
        self.notifyHungApps = Self.bool(defaults, Key.notifyHungApps, default: Self.defaultNotifyHungApps)
        self.notifyAppUpdates = Self.bool(defaults, Key.notifyAppUpdates, default: Self.defaultNotifyAppUpdates)
        self.installUpdatesAutomatically = Self.bool(defaults, Key.installUpdatesAutomatically, default: Self.defaultInstallUpdatesAutomatically)
        self.notifyDefinitionsStale = Self.bool(defaults, Key.notifyDefinitionsStale, default: Self.defaultNotifyDefinitionsStale)
        self.notificationSoundsEnabled = Self.bool(defaults, Key.notificationSoundsEnabled, default: Self.defaultNotificationSoundsEnabled)
        let storedLaunchAtLogin = Self.bool(defaults, Key.launchAtLogin, default: Self.defaultLaunchAtLogin)
        self.launchAtLogin = storedLaunchAtLogin
        self.acceptedLaunchAtLogin = storedLaunchAtLogin
        self.showMenuBar = Self.bool(defaults, Key.showMenuBar, default: Self.defaultShowMenuBar)
        self.keepDockIcon = Self.bool(defaults, Key.keepDockIcon, default: Self.defaultKeepDockIcon)
        self.statsUpdateInterval = (defaults.object(forKey: Key.statsUpdateInterval) as? Double)
            ?? Self.defaultStatsUpdateInterval
        self.panelRowStates = (defaults.dictionary(forKey: Key.panelRowStates) as? [String: Bool]) ?? [:]
        // An explicit choice wins; otherwise fall back to the boolean this
        // replaced so someone who opted into the free-space readout keeps it.
        if let raw = defaults.string(forKey: Key.menuBarReading),
           let stored = MenuBarReading(rawValue: raw) {
            self.menuBarReading = stored
        } else if let legacy = defaults.object(forKey: Key.menuBarShowsReading) as? Bool {
            self.menuBarReading = legacy ? .freeSpace : .none
        } else {
            self.menuBarReading = Self.defaultMenuBarReading
        }
        self.menuBarShowsReading = Self.bool(defaults, Key.menuBarShowsReading, default: Self.defaultMenuBarShowsReading)

        // `menuBarPresence` models a three-way in which "neither" is
        // unreachable, so the getter reports Dock-only when both flags are off.
        // A hand-edited defaults file can still hold that pair, and because the
        // picker's selection already *equals* Dock-only, choosing it is a no-op
        // — the state can never be corrected from the UI. Collapse it once here
        // so the model matches what the picker says about it.
        if !showMenuBar && !keepDockIcon {
            keepDockIcon = true
        }

        // Reconcile the persisted preference with launchd's actual state once
        // the tracked properties are populated. The handler's presence is the
        // signal that we're in production wiring (tests pass nil); skipping in
        // tests keeps unit tests from mutating the host's login items. The
        // write runs off the main actor, so the app's launch never waits on
        // launchd.
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
        notifyAppUpdates = Self.defaultNotifyAppUpdates
        installUpdatesAutomatically = Self.defaultInstallUpdatesAutomatically
        notifyDefinitionsStale = Self.defaultNotifyDefinitionsStale
        notificationSoundsEnabled = Self.defaultNotificationSoundsEnabled
        launchAtLogin = Self.defaultLaunchAtLogin
        showMenuBar = Self.defaultShowMenuBar
        menuBarShowsReading = Self.defaultMenuBarShowsReading
        menuBarReading = Self.defaultMenuBarReading
        keepDockIcon = Self.defaultKeepDockIcon
        statsUpdateInterval = Self.defaultStatsUpdateInterval
        panelRowStates = [:]
    }

    // MARK: - Side effects

    /// Throwing entry point for surfaces that present their own inline failure
    /// (the Performance view's Login Items row). Applies the launch-at-login
    /// change through the same handler the property setter uses — keeping
    /// `SMAppService` access in one place (issue #65) — but rethrows any failure
    /// to the caller instead of routing it to the global alert reporter, so the
    /// error can be shown inline without double-reporting. On success it updates
    /// and persists the tracked value, keeping the Preferences toggle in lockstep
    /// — unless a newer change was made while launchd answered, which then
    /// decides it. Returns once launchd has answered.
    func setLaunchAtLogin(_ enabled: Bool) async throws {
        // The tracked value only moves once the write succeeds, so a failure
        // propagates before the model changes. The write updates it behind
        // `isApplyingLaunchAtLogin`, keeping the handler running exactly once
        // per change.
        try await writeLaunchAtLogin(enabled, reportingFailure: false).value
    }

    /// Returns once every launch-at-login write requested so far has finished.
    /// For a reader that must see launchd's answer rather than the state the
    /// write is replacing — the Performance Login Items row re-reads
    /// `SMAppService` after each change.
    func waitForLaunchAtLoginWrites() async {
        _ = await launchAtLoginWrite?.result
    }

    /// Pushes the current `launchAtLogin` value through the injected handler
    /// (in production, `LoginItemManager.setEnabled`). Errors are forwarded to
    /// the optional reporter so the App layer can surface an alert without
    /// coupling the model to AppKit.
    private func applyLaunchAtLogin() {
        guard launchAtLoginHandler != nil else { return }
        writeLaunchAtLogin(launchAtLogin, reportingFailure: true)
    }

    /// Hands `enabled` to launchd through the injected handler, off the main
    /// actor: `SMAppService.register()` and `unregister()` block until launchd
    /// answers, and on the main actor that freezes the UI for as long as it
    /// takes. The write waits for every earlier one first, so writes reach
    /// launchd one at a time and in the order they were made. The returned
    /// task finishes once launchd has answered, throwing whatever the handler
    /// threw.
    @discardableResult
    private func writeLaunchAtLogin(_ enabled: Bool, reportingFailure: Bool) -> Task<Void, any Error> {
        let handler = launchAtLoginHandler
        let earlier = launchAtLoginWrite
        launchAtLoginWriteGeneration += 1
        let generation = launchAtLoginWriteGeneration
        let write = Task {
            _ = await earlier?.result
            do {
                if let handler {
                    try await Task.detached(priority: .userInitiated) {
                        try handler(enabled)
                    }.value
                }
                acceptedLaunchAtLogin = enabled
                finishLaunchAtLoginWrite(generation, failure: nil, reportingFailure: reportingFailure)
            } catch {
                finishLaunchAtLoginWrite(generation, failure: error, reportingFailure: reportingFailure)
                throw error
            }
        }
        launchAtLoginWrite = write
        return write
    }

    /// Settles the toggle once a write has finished. Only the newest write
    /// decides what the toggle shows and whether a failure raises the alert;
    /// one that a newer change has superseded leaves both to that change.
    ///
    /// The newest write brings the tracked value in line with what launchd
    /// last accepted. After a failure that means going back, because launchd
    /// is still there: the write is what failed. Without the revert the model
    /// — and `UserDefaults` — would claim a state the login item never
    /// reached, and `init`'s reconcile would re-attempt (and re-alert on) that
    /// same failing write at every launch, with no way to clear it from the
    /// toggle.
    private func finishLaunchAtLoginWrite(_ generation: Int, failure: (any Error)?, reportingFailure: Bool) {
        guard generation == launchAtLoginWriteGeneration else {
            if let failure, reportingFailure {
                log.error("Superseded launch-at-login write failed: \(failure.localizedDescription, privacy: .private)")
            }
            return
        }
        if launchAtLogin != acceptedLaunchAtLogin {
            // The nested `didSet` persists the settled value; the flag stops
            // it from sending launchd a write it has just answered.
            isApplyingLaunchAtLogin = true
            launchAtLogin = acceptedLaunchAtLogin
            isApplyingLaunchAtLogin = false
        }
        if let failure, reportingFailure {
            launchAtLoginErrorReporter?(failure)
        }
    }
}
