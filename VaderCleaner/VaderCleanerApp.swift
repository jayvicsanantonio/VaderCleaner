// VaderCleanerApp.swift
// App entry point — defines the SwiftUI App lifecycle for VaderCleaner.

import SwiftUI
import AppKit

@main
struct VaderCleanerApp: App {

    /// Identifier shared between the main `WindowGroup` and the menu bar's
    /// "Open VaderCleaner" action so `openWindow(id:)` can re-focus or
    /// re-create the window after the user has closed it.
    static let mainWindowID = "main"

    // App-scope state owned outside the WindowGroup so dismissing the FDA
    // onboarding sheet (or any future session-wide flag) holds across all
    // windows the user might open. A per-view @StateObject in ContentView
    // would be re-created per WindowGroup instance.
    @StateObject private var appState = AppState()
    @StateObject private var onboardingViewModel = PermissionOnboardingViewModel()
    @StateObject private var menuBarViewModel = MenuBarViewModel()
    @NSApplicationDelegateAdaptor(VaderCleanerAppDelegate.self) private var appDelegate

    init() {
        HelperRegistration.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(onboardingViewModel)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(menuBarViewModel)
        } label: {
            // Compact label combining both placeholder readings — Prompt 10
            // replaces the values, not the format.
            Text("\(menuBarViewModel.formattedRAMUsage) | \(menuBarViewModel.formattedDiskSpace)")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Drives the Dock icon's lifecycle. With `LSUIElement = YES` the app launches
/// with no Dock icon; we promote to `.regular` once the main window is up so
/// the user has a Dock entry, then demote back to `.accessory` when the last
/// titled window closes so the menu bar extra can keep running headlessly.
final class VaderCleanerAppDelegate: NSObject, NSApplicationDelegate {

    private var windowCloseObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Show the Dock icon as soon as launch begins; the SwiftUI WindowGroup
        // opens the main window immediately afterwards. Setting policy this
        // early avoids the brief flicker of an icon-less Dock that would
        // happen if we deferred to the window's `onAppear`.
        NSApp.setActivationPolicy(.regular)
        installWindowCloseObserver()
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

    private func installWindowCloseObserver() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowWillClose(notification)
        }
    }

    private func handleWindowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow

        // The MenuBarExtra popover is a borderless utility window — only
        // titled windows count as "main app windows" for Dock-icon purposes.
        // We exclude the closing window itself because it is still in
        // `NSApp.windows` at notification time.
        let hasOtherTitledWindow = NSApp.windows.contains { window in
            guard window !== closingWindow else { return false }
            return window.isVisible && window.styleMask.contains(.titled)
        }

        if !hasOtherTitledWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    deinit {
        if let token = windowCloseObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
