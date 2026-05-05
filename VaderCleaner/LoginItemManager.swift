// LoginItemManager.swift
// Thin wrapper around SMAppService.mainApp for the launch-at-login preference.

import Foundation
import ServiceManagement
import os.log

/// Toggles VaderCleaner's "launch at login" registration.
///
/// `SMAppService.mainApp` registers the host bundle with launchd so the system
/// starts the app at user login — replacing the deprecated
/// `SMLoginItemSetEnabled` API on macOS 13+. The wrapper exists for two
/// reasons:
///   - Idempotence: `register()` and `unregister()` throw if the service is
///     already in the requested state, which would surface on every preference
///     toggle as a spurious error. We short-circuit when `status` already
///     matches.
///   - A single seam to log against, so the menu bar / Settings flows can call
///     in without each duplicating error reporting.
enum LoginItemManager {

    private static let log = OSLog(
        subsystem: "com.personal.VaderCleaner",
        category: "LoginItemManager"
    )

    /// `true` when launchd reports the main app as an active login item.
    /// Reads the live status, so flipping the toggle in System Settings →
    /// Login Items is reflected immediately on the next read.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers (or unregisters) the host app with launchd. No-op when the
    /// requested state already matches `service.status`, so this is safe to
    /// call from a `didSet` that fires on every preference write.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp

        if enabled {
            // `.enabled` means launchd already has us registered. Calling
            // register() again would throw `kSMErrorAlreadyRegistered`.
            guard service.status != .enabled else {
                os_log("Already enabled; skipping register()", log: log, type: .debug)
                return
            }
            try service.register()
            os_log("Registered as login item (status=%{public}@)",
                   log: log, type: .info, String(describing: service.status))
        } else {
            // `.requiresApproval` means launchd has the entry but the user
            // hasn't yet approved it in System Settings — it is still
            // registered, so calling unregister() must succeed for the
            // off-toggle to actually take effect. Only `.notRegistered` /
            // `.notFound` represent "nothing to undo".
            guard service.status == .enabled || service.status == .requiresApproval else {
                os_log("Not registered; skipping unregister()", log: log, type: .debug)
                return
            }
            try service.unregister()
            os_log("Unregistered as login item (status=%{public}@)",
                   log: log, type: .info, String(describing: service.status))
        }
    }
}
