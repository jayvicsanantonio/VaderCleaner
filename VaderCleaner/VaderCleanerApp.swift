// VaderCleanerApp.swift
// App entry point — defines the SwiftUI App lifecycle for VaderCleaner.

import SwiftUI

@main
struct VaderCleanerApp: App {
    // App-scope state owned outside the WindowGroup so dismissing the FDA
    // onboarding sheet (or any future session-wide flag) holds across all
    // windows the user might open. A per-view @StateObject in ContentView
    // would be re-created per WindowGroup instance.
    @StateObject private var appState = AppState()
    @StateObject private var onboardingViewModel = PermissionOnboardingViewModel()

    init() {
        HelperRegistration.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(onboardingViewModel)
        }
    }
}
