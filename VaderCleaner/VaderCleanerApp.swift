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
    @StateObject private var menuBarViewModel = MenuBarViewModel()
    @StateObject private var preferences = PreferencesStore()
    @StateObject private var exclusions = ExclusionsStore()
    @NSApplicationDelegateAdaptor(VaderCleanerAppDelegate.self) private var appDelegate

    init() {
        HelperRegistration.registerIfNeeded()
    }

    var body: some Scene {
        Window("VaderCleaner", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(onboardingViewModel)
                .environmentObject(preferences)
                .environmentObject(exclusions)
        }

        // Each SwiftUI scene gets its own environment, so PreferencesView gets
        // its own `.environmentObject` chain — environment objects on the
        // `Window` scene above don't bleed across to `Settings`.
        Settings {
            PreferencesView()
                .environmentObject(preferences)
                .environmentObject(exclusions)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(menuBarViewModel)
                .environmentObject(preferences)
                .environmentObject(exclusions)
        } label: {
            // Compact label combining both placeholder readings — Prompt 10
            // replaces the values, not the format. The "RAM:" / "Disk:"
            // prefixes live here (and on the popover rows) so the view-model
            // can stay value-only and avoid duplicated labels.
            Text("RAM: \(menuBarViewModel.formattedRAMUsage) | Disk: \(menuBarViewModel.formattedDiskSpace)")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Drives the Dock icon's lifecycle. With `LSUIElement = YES` the app launches
/// with no Dock icon; we promote to `.regular` once a titled window is up so
/// the user has a Dock entry, then demote back to `.accessory` when the last
/// titled window closes so the menu bar extra can keep running headlessly.
///
/// Two observers cooperate to keep the policy in sync with window lifecycle:
///   - `NSWindow.didBecomeKeyNotification` re-promotes when a titled window
///     re-appears (e.g. user picks "Open VaderCleaner" from the menu bar after
///     the previous window had been closed and the policy was demoted).
///   - `NSWindow.willCloseNotification` demotes once the closing window leaves
///     no other titled window in `NSApp.windows`.
final class VaderCleanerAppDelegate: NSObject, NSApplicationDelegate {

    private var windowCloseObserver: NSObjectProtocol?
    private var windowKeyObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Show the Dock icon as soon as launch begins; the SwiftUI WindowGroup
        // opens the main window immediately afterwards. Setting policy this
        // early avoids the brief flicker of an icon-less Dock that would
        // happen if we deferred to the window's `onAppear`.
        NSApp.setActivationPolicy(.regular)
        installWindowObservers()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Clicking the Dock icon while the main window is closed should
        // restore it. Returning `true` lets AppKit forward the reopen event
        // to SwiftUI, which re-creates the WindowGroup window.
        return true
    }

    private func installWindowObservers() {
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

        if !hasOtherTitledWindow {
            NSApp.setActivationPolicy(.accessory)
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
    }
}
