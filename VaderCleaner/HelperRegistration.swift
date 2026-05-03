// HelperRegistration.swift
// Registers VaderCleanerHelper as a privileged daemon via SMAppService at app launch.

import Foundation
import ServiceManagement
import os.log

/// Registers the VaderCleanerHelper daemon with launchd via SMAppService.
///
/// Registration requires the helper executable and the host app to be code-signed —
/// see HelperConnectionManager for the manual ad-hoc signing step in development.
/// Failures are logged but do not propagate; the app continues to run normally and
/// the helper simply remains unavailable until signing is in place.
enum HelperRegistration {

    private static let log = OSLog(subsystem: "com.personal.VaderCleaner", category: "HelperRegistration")
    private static let plistName = "com.personal.VaderCleaner.helper.plist"

    static func registerIfNeeded() {
        let service = SMAppService.daemon(plistName: plistName)
        // Skip if already registered — register() throws when the service is already
        // enabled, which would generate noise in Console on every launch.
        guard service.status != .enabled else {
            os_log("Helper daemon already registered (status=%{public}@)",
                   log: log, type: .debug, String(describing: service.status))
            return
        }
        do {
            try service.register()
            os_log("Registered helper daemon (status=%{public}@)",
                   log: log, type: .info, String(describing: service.status))
        } catch {
            os_log("Helper daemon registration failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }
}
