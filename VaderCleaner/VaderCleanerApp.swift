// VaderCleanerApp.swift
// App entry point — defines the SwiftUI App lifecycle for VaderCleaner.

import SwiftUI

@main
struct VaderCleanerApp: App {
    @StateObject private var appState = AppState()

    init() {
        HelperRegistration.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
