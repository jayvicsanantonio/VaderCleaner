// AppRelauncher.swift
// Starts a fresh instance of the running app and quits this one, which is how a Full Disk Access grant reaches a process that was already running.

import AppKit
import os

/// Replaces the running process with a new one. macOS applies Full Disk Access
/// to a process started after the grant, so this is the one-click version of
/// "quit and reopen".
public enum AppRelauncher {

    private static let log = Logger(subsystem: "com.personal.VaderCleaner",
                                    category: "AppRelauncher")

    /// Production wiring: launches a second instance of this bundle, because
    /// asking LaunchServices to open an app that is already running would just
    /// bring this process forward.
    @MainActor
    public static func relaunch() async {
        await relaunch(
            openNewInstance: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                _ = try await NSWorkspace.shared.openApplication(
                    at: Bundle.main.bundleURL,
                    configuration: configuration
                )
            },
            terminate: { _ = NSRunningApplication.current.terminate() }
        )
    }

    /// Quits only once the replacement is up, so a failed launch leaves the user
    /// in the app they were using rather than with no app at all.
    @MainActor
    static func relaunch(
        openNewInstance: () async throws -> Void,
        terminate: () -> Void
    ) async {
        do {
            try await openNewInstance()
        } catch {
            log.error("Relaunch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        terminate()
    }
}
