// VaderCleanerApp.swift
// App entry point — defines the SwiftUI App lifecycle for VaderCleaner.

import SwiftUI
import AppKit

@main
struct VaderCleanerApp: App {

    /// Identifier shared between the main `Window` scene and the menu bar's
    /// "Open VaderCleaner" action so `openWindow(id:)` can re-focus or
    /// re-create the window after the user has closed it.
    ///
    /// VaderCleaner intentionally uses a single-instance `Window` (not
    /// `WindowGroup`): `openWindow(id:)` against a `WindowGroup` would spawn
    /// a fresh window on every invocation, leaving the user with stacks of
    /// duplicates each time they tapped the menu bar action.
    static let mainWindowID = "main"

    // App-scope state owned outside the WindowGroup so dismissing the FDA
    // onboarding sheet (or any future session-wide flag) holds across all
    // windows the user might open. A per-view @State in ContentView would
    // be re-created per WindowGroup instance.
    @State private var appState = AppState()
    @State private var onboardingViewModel = PermissionOnboardingViewModel()
    @State private var menuBarViewModel: MenuBarViewModel
    @State private var preferences: PreferencesStore
    @State private var exclusions: ExclusionsStore
    @State private var smartScanSettings: SmartScanSettingsStore
    @State private var systemJunkViewModel: SystemJunkViewModel
    @State private var largeOldFilesViewModel: LargeOldFilesViewModel
    @State private var spaceLensViewModel: DiskScannerViewModel
    @State private var spaceLensViewMode: SpaceLensViewModeStore
    @State private var privacyViewModel: PrivacyViewModel
    @State private var appUninstallerViewModel: AppUninstallerViewModel
    @State private var appUpdaterViewModel: AppUpdaterViewModel
    @State private var applicationsViewModel: ApplicationsViewModel
    @State private var extensionsManagerViewModel: ExtensionsManagerViewModel
    @State private var optimizationViewModel: OptimizationViewModel
    @State private var malwareViewModel: MalwareViewModel
    @State private var smartScanViewModel: SmartScanViewModel
    // App-scope so the cheap-stats timer outlives any single window. The
    // Health Monitor view (Prompt 9), the menu bar (Prompt 10), and the
    // notification dispatcher (Prompt 11) all subscribe via
    // `@EnvironmentObject` — making it a per-view StateObject would
    // double-instantiate the timer.
    @State private var systemStats: SystemStatsService
    // App-scope list of connected Bluetooth devices and ejectable volumes for
    // the menu's Connected Devices tile. `autoRefresh: false` so it does NOT
    // touch Bluetooth (a TCC-gated resource) during App.init — that runs before
    // the app can present a permission prompt and would crash a menu-bar agent
    // app at launch. The panel refreshes the list when the menu opens instead.
    @State private var connectedDevices = ConnectedDevicesMonitor(autoRefresh: false)
    // App-scope router so the menu bar panel can deep-link into a main-window
    // section (and optionally start its scan). Shared by both scenes.
    @State private var menuRouter = MenuRouter()
    // App-scope: subscribes to `systemStats` and pushes notifications via
    // `NotificationManager`. Held here so the Combine subscriptions live as
    // long as the app and so the per-kind cooldown table survives across
    // window open/close cycles.
    @State private var notificationMonitor: NotificationThresholdMonitor
    @NSApplicationDelegateAdaptor(VaderCleanerAppDelegate.self) private var appDelegate

    init() {
        HelperRegistration.registerIfNeeded()
        // Construct the store with production side-effect handlers. The init
        // also reconciles the persisted preference with `SMAppService` so a
        // user who toggled "Login Items" in System Settings while VaderCleaner
        // was quit gets pushed back into a consistent state on the next
        // launch.
        let prefs = PreferencesStore(
            launchAtLoginHandler: { try LoginItemManager.setEnabled($0) },
            launchAtLoginErrorReporter: VaderCleanerApp.presentLaunchAtLoginAlert(_:)
        )
        _preferences = State(initialValue: prefs)
        // Feature-session view models live at app scope so sidebar navigation
        // rebuilds only their views, not their production collaborators or
        // in-progress scan/selection state. The scanner models capture this
        // same exclusions store and snapshot it per scan.
        let exclusions = ExclusionsStore()
        _exclusions = State(initialValue: exclusions)
        // "Customize Smart Care" choices (which Smart Scan modules and System
        // Junk categories to include). Captured by `SmartScanViewModel.live`
        // below, which snapshots it per scan so a Settings toggle takes effect
        // on the next run.
        let smartScanSettings = SmartScanSettingsStore()
        _smartScanSettings = State(initialValue: smartScanSettings)
        _systemJunkViewModel = State(
            initialValue: SystemJunkViewModel.live(exclusions: exclusions)
        )
        _largeOldFilesViewModel = State(
            initialValue: LargeOldFilesViewModel.live(exclusions: exclusions)
        )
        _spaceLensViewModel = State(
            initialValue: DiskScannerViewModel.live(exclusions: exclusions)
        )
        // UI tests pass an isolated UserDefaults suite name so toggling the
        // Space Lens view mode during a test doesn't mutate the developer's
        // real preference. Production never sets this, so it falls back to
        // `.standard`. This is real persistence pointed at a scratch domain,
        // not a mock.
        let viewModeDefaults = ProcessInfo.processInfo
            .environment["UITEST_DEFAULTS_SUITE"]
            .flatMap { UserDefaults(suiteName: $0) } ?? .standard
        _spaceLensViewMode = State(initialValue: SpaceLensViewModeStore(defaults: viewModeDefaults))
        _privacyViewModel = State(initialValue: PrivacyViewModel.live())
        _appUninstallerViewModel = State(
            initialValue: AppUninstallerViewModel.live(exclusions: exclusions)
        )
        _appUpdaterViewModel = State(initialValue: AppUpdaterViewModel.live())
        // The Applications dashboard's own scan (installed-app count + update
        // count). The uninstall / update side-effects stay owned by the two
        // view models above, which the dashboard reuses as detail screens.
        _applicationsViewModel = State(initialValue: ApplicationsViewModel.live())
        _extensionsManagerViewModel = State(initialValue: ExtensionsManagerViewModel.live())
        // Construct the polling service and the menu bar view-model in the
        // same init so both `@StateObject` wrappers reference the *same*
        // service instance. Initializing `menuBarViewModel` at its property
        // declaration would force a separate `SystemStatsService()` —
        // doubling the polling timer and decoupling the menu bar from the
        // service the Health Monitor consumes.
        let stats = SystemStatsService()
        _systemStats = State(initialValue: stats)
        // Wired after `stats` so the Optimization RAM figures come from the
        // same polling service the Health Monitor and menu bar consume.
        _optimizationViewModel = State(
            initialValue: OptimizationViewModel.live(systemStats: stats, preferences: prefs)
        )
        _menuBarViewModel = State(initialValue: MenuBarViewModel(service: stats))
        // One NotificationManager for the whole app. Its init registers
        // itself as the `UNUserNotificationCenter` delegate (a weak property);
        // a second instance would silently steal that registration, so the
        // threshold monitor and the Malware feature share this one.
        let notificationManager = NotificationManager()
        // Wired after `stats` so manual malware scans surface a detection
        // banner through the same dispatcher the threshold monitor uses, and
        // honour the same `notifyMalwareFound` preference.
        _malwareViewModel = State(
            initialValue: MalwareViewModel.live(
                dispatcher: notificationManager,
                preferences: prefs
            )
        )
        // Smart Scan orchestrates the System Junk, Malware, and Optimization
        // collaborators behind one flow. It captures the same exclusions store
        // the standalone junk scanner uses and snapshots it per scan, so an
        // exclusion added in Preferences takes effect on the next Smart Scan.
        _smartScanViewModel = State(
            initialValue: SmartScanViewModel.live(exclusions: exclusions, settings: smartScanSettings)
        )
        // Wire the notification monitor to the same stats + preferences
        // instances the rest of the app sees. The monitor holds the manager
        // strongly via `dispatcher`, and ContentView drives the permission
        // request through `monitor.requestPermission()` after the FDA
        // onboarding sheet has settled — so we don't need a separate App-
        // level reference to the manager.
        _notificationMonitor = State(
            initialValue: NotificationThresholdMonitor(
                stats: stats,
                preferences: prefs,
                dispatcher: notificationManager
            )
        )
    }

    /// Surfaces a launchd registration failure to the user. Kept on the App
    /// type (rather than inside the store) so the model layer remains free of
    /// AppKit references and continues to be unit-testable without `NSAlert`.
    ///
    /// The alert is dispatched asynchronously because the very first call site
    /// is `PreferencesStore.init` running inside `VaderCleanerApp.init()` —
    /// before `NSApp` has finished launching. Presenting a modal there would
    /// race the run loop and could deadlock startup. The async hop guarantees
    /// the alert lands after the app is up.
    @MainActor
    private static func presentLaunchAtLoginAlert(_ error: Error) {
        let description = error.localizedDescription
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Couldn't update Launch at Login"
            alert.informativeText = """
            VaderCleaner couldn't update its Launch at Login setting. \
            You can manage this manually from System Settings → General → Login Items.

            Details: \(description)
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Shows the standard macOS About panel. Version and build are read
    /// automatically from the bundle's `CFBundleShortVersionString` /
    /// `CFBundleVersion`; we supply the credits so the panel isn't blank.
    /// The copyright line is folded into `credits` rather than passed via
    /// the `Copyright` option key — that key is only honoured on macOS 15+
    /// and the app deploys back to macOS 14, where it would be silently
    /// dropped. Activating first guarantees the panel comes forward even
    /// when invoked while the app has no key window.
    @MainActor
    private static func showAboutPanel() {
        let credits = NSAttributedString(
            string: """
            A native macOS cleaner: junk, large files, malware, privacy, and system health.

            © 2026 Jayvic San Antonio
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    var body: some Scene {
        Window("VaderCleaner", id: Self.mainWindowID) {
            ContentView(
                systemJunkViewModel: systemJunkViewModel,
                largeOldFilesViewModel: largeOldFilesViewModel,
                spaceLensViewModel: spaceLensViewModel,
                spaceLensViewMode: spaceLensViewMode,
                privacyViewModel: privacyViewModel,
                appUninstallerViewModel: appUninstallerViewModel,
                appUpdaterViewModel: appUpdaterViewModel,
                applicationsViewModel: applicationsViewModel,
                extensionsManagerViewModel: extensionsManagerViewModel,
                optimizationViewModel: optimizationViewModel,
                malwareViewModel: malwareViewModel,
                smartScanViewModel: smartScanViewModel
            )
                .environment(appState)
                .environment(onboardingViewModel)
                .environment(preferences)
                .environment(exclusions)
                .environment(systemStats)
                .environment(notificationMonitor)
                .environment(menuRouter)
        }
        // Hide the title bar so no section title is drawn beside the traffic
        // lights; the controls float over the section's gradient and each
        // screen reads as one continuous surface.
        .windowStyle(.hiddenTitleBar)
        // Open wide and tall enough for the side-by-side section intro (hero
        // beside the text) to show on first launch, with the vertically
        // centred cluster sitting clear of the floating Scan disc.
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Replace SwiftUI's default "About VaderCleaner" item so the
            // panel carries our copyright credits instead of an empty one.
            CommandGroup(replacing: .appInfo) {
                Button("About VaderCleaner") {
                    VaderCleanerApp.showAboutPanel()
                }
            }
        }

        // Each SwiftUI scene gets its own environment, so PreferencesView gets
        // its own `.environmentObject` chain — environment objects on the
        // `Window` scene above don't bleed across to `Settings`.
        Settings {
            PreferencesView()
                .environment(preferences)
                .environment(exclusions)
                .environment(smartScanSettings)
        }

        // `isInserted:` makes the menu bar extra disappear when the user
        // disables "Show VaderCleaner in the menu bar" in Preferences. The
        // binding routes through `PreferencesStore.showMenuBar` so toggling
        // the preference takes effect immediately and survives relaunch.
        //
        // The `set` closure short-circuits identical writes. SwiftUI calls
        // `MenuBarExtra(isInserted:)`'s setter back during scene layout, so an
        // unguarded write would notify observers redundantly even when the
        // value hasn't changed; the guard keeps the menu bar's insertion
        // state from invalidating views that don't actually need to update.
        MenuBarExtra(
            isInserted: Binding(
                get: { preferences.showMenuBar },
                set: { newValue in
                    if newValue != preferences.showMenuBar {
                        preferences.showMenuBar = newValue
                    }
                }
            )
        ) {
            MenuBarContent()
                .environment(menuBarViewModel)
                .environment(preferences)
                .environment(exclusions)
                .environment(systemStats)
                .environment(connectedDevices)
                .environment(malwareViewModel)
                .environment(menuRouter)
        } label: {
            // A compact health-pulse glyph by default. A wide text label gets
            // pushed into the area hidden behind the notch on a crowded menu bar
            // and becomes invisible; the narrow icon stays reachable and matches
            // how menu bar apps conventionally present themselves. Users who
            // want a number can opt into a short free-disk reading beside it
            // (Preferences → "Show free space in the menu bar"). The full
            // readings live in the panel; the text stays the accessibility label.
            if preferences.menuBarShowsReading {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                    Text(menuBarViewModel.menuBarCompactReading)
                        .monospacedDigit()
                }
                .accessibilityLabel(menuBarViewModel.menuBarLabelText)
            } else {
                Image(systemName: "waveform.path.ecg")
                    .accessibilityLabel(menuBarViewModel.menuBarLabelText)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Drives the Dock icon's lifecycle. With `LSUIElement = YES` the app launches
/// with no Dock icon; we promote to `.regular` once a titled window is up so
/// the user has a Dock entry, and may demote to `.accessory` when the last
/// titled window closes so the menu bar extra can keep running headlessly —
/// but only if the menu bar extra is actually showing. Otherwise the user
/// would have no entry point left to reopen the app, so we stay `.regular`.
///
/// Three observers cooperate to keep the policy in sync:
///   - `NSWindow.didBecomeKeyNotification` re-promotes when a titled window
///     re-appears (e.g. user picks "Open VaderCleaner" from the menu bar after
///     the previous window had been closed).
///   - `NSWindow.willCloseNotification` re-evaluates once the closing window
///     leaves no other titled window in `NSApp.windows`.
///   - `UserDefaults.didChangeNotification` re-evaluates when any preference
///     toggles, so flipping `showMenuBar` from on to off while no window is
///     open promptly reveals the Dock icon.
final class VaderCleanerAppDelegate: NSObject, NSApplicationDelegate {

    private var windowCloseObserver: NSObjectProtocol?
    private var windowKeyObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Show the Dock icon as soon as launch begins; the SwiftUI Window
        // scene opens the main window immediately afterwards. Setting policy
        // this early avoids the brief flicker of an icon-less Dock that would
        // happen if we deferred to the window's `onAppear`. The reconcile
        // logic only runs on later events, so this unconditional `.regular`
        // here is intentional and correct at launch.
        NSApp.setActivationPolicy(.regular)
        installObservers()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Clicking the Dock icon while the main window is closed should
        // restore it. Returning `true` lets AppKit forward the reopen event
        // to SwiftUI, which re-creates the window.
        return true
    }

    private func installObservers() {
        let center = NotificationCenter.default

        windowCloseObserver = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowWillClose(notification)
        }

        windowKeyObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowDidBecomeKey(notification)
        }

        // `UserDefaults.didChangeNotification` fires for every key in the
        // suite, not only `showMenuBar`. The reconcile is cheap (one read +
        // one comparison + at most one `setActivationPolicy`), so we don't
        // bother filtering — every preference toggle is a fine moment to
        // re-check whether the user still has an entry point.
        preferencesObserver = center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileActivationPolicy()
        }
    }

    private func handleWindowDidBecomeKey(_ notification: Notification) {
        // Only titled windows count as "main app windows" — the menu bar
        // extra's popover is borderless and would otherwise re-promote the
        // app every time the user clicked the menu bar icon.
        guard
            let window = notification.object as? NSWindow,
            window.styleMask.contains(.titled)
        else { return }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func handleWindowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow

        // Count any other titled window — including minimized ones — as a
        // reason to keep the Dock icon. Filtering by `isVisible` would drop
        // the icon while a minimized window still exists, leaving that window
        // unreachable. We exclude the closing window itself because it is
        // still present in `NSApp.windows` at notification time.
        let hasOtherTitledWindow = NSApp.windows.contains { window in
            guard window !== closingWindow else { return false }
            return window.styleMask.contains(.titled)
        }

        applyPolicy(hasTitledWindow: hasOtherTitledWindow)
    }

    /// Recomputes the policy from scratch using the current window state and
    /// menu-bar preference. Safe to call from any event source — only writes
    /// `setActivationPolicy` when the value actually changes.
    private func reconcileActivationPolicy() {
        let hasTitledWindow = NSApp.windows.contains {
            $0.styleMask.contains(.titled)
        }
        applyPolicy(hasTitledWindow: hasTitledWindow)
    }

    private func applyPolicy(hasTitledWindow: Bool) {
        let policy = ActivationPolicyDecision.policy(
            hasTitledWindow: hasTitledWindow,
            menuBarShown: PreferencesStore.isMenuBarShown()
        )
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    deinit {
        let center = NotificationCenter.default
        if let token = windowCloseObserver {
            center.removeObserver(token)
        }
        if let token = windowKeyObserver {
            center.removeObserver(token)
        }
        if let token = preferencesObserver {
            center.removeObserver(token)
        }
    }
}
