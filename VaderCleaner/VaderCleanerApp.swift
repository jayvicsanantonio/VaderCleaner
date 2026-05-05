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
    // windows the user might open. A per-view @StateObject in ContentView
    // would be re-created per WindowGroup instance.
    @StateObject private var appState = AppState()
    @StateObject private var onboardingViewModel = PermissionOnboardingViewModel()
    @StateObject private var menuBarViewModel: MenuBarViewModel
    @StateObject private var preferences: PreferencesStore
    @StateObject private var exclusions = ExclusionsStore()
    // App-scope so the cheap-stats timer outlives any single window. The
    // Health Monitor view (Prompt 9), the menu bar (Prompt 10), and the
    // notification dispatcher (Prompt 11) all subscribe via
    // `@EnvironmentObject` — making it a per-view StateObject would
    // double-instantiate the timer.
    @StateObject private var systemStats: SystemStatsService
    @NSApplicationDelegateAdaptor(VaderCleanerAppDelegate.self) private var appDelegate

    init() {
        HelperRegistration.registerIfNeeded()
        // Construct the store with production side-effect handlers. The init
        // also reconciles the persisted preference with `SMAppService` so a
        // user who toggled "Login Items" in System Settings while VaderCleaner
        // was quit gets pushed back into a consistent state on the next
        // launch.
        _preferences = StateObject(
            wrappedValue: PreferencesStore(
                launchAtLoginHandler: { try LoginItemManager.setEnabled($0) },
                launchAtLoginErrorReporter: VaderCleanerApp.presentLaunchAtLoginAlert(_:)
            )
        )
        // Construct the polling service and the menu bar view-model in the
        // same init so both `@StateObject` wrappers reference the *same*
        // service instance. Initializing `menuBarViewModel` at its property
        // declaration would force a separate `SystemStatsService()` —
        // doubling the polling timer and decoupling the menu bar from the
        // service the Health Monitor consumes.
        let stats = SystemStatsService()
        _systemStats = StateObject(wrappedValue: stats)
        _menuBarViewModel = StateObject(wrappedValue: MenuBarViewModel(service: stats))
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

    var body: some Scene {
        Window("VaderCleaner", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(onboardingViewModel)
                .environmentObject(preferences)
                .environmentObject(exclusions)
                .environmentObject(systemStats)
        }

        // Each SwiftUI scene gets its own environment, so PreferencesView gets
        // its own `.environmentObject` chain — environment objects on the
        // `Window` scene above don't bleed across to `Settings`.
        Settings {
            PreferencesView()
                .environmentObject(preferences)
                .environmentObject(exclusions)
        }

        // `isInserted:` makes the menu bar extra disappear when the user
        // disables "Show VaderCleaner in the menu bar" in Preferences. The
        // binding routes through `PreferencesStore.showMenuBar` so toggling
        // the preference takes effect immediately and survives relaunch.
        //
        // The `set` closure short-circuits identical writes. SwiftUI calls
        // `MenuBarExtra(isInserted:)`'s setter back during scene layout — and
        // because `@Published` always fires `objectWillChange.send()` even
        // when the value is unchanged, an unguarded `$preferences.showMenuBar`
        // produces a flood of "Publishing changes from within view updates"
        // warnings and hangs the UI test runner.
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
                .environmentObject(menuBarViewModel)
                .environmentObject(preferences)
                .environmentObject(exclusions)
                .environmentObject(systemStats)
        } label: {
            // Compact label rendered into the system menu bar. The format
            // (prefixes, separator, truncation rules) lives on
            // `MenuBarViewModel.menuBarLabel(ram:disk:)` so a buggy upstream
            // reading can't blow up label width — the view-model clamps each
            // segment before formatting. `.monospacedDigit()` keeps numeric
            // glyphs fixed-width so neighbouring menu bar items don't jitter
            // as readings change every two seconds.
            Text(menuBarViewModel.menuBarLabelText)
                .monospacedDigit()
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
