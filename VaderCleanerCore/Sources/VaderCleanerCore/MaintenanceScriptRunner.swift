// MaintenanceScriptRunner.swift
// Bridges the privileged runMaintenanceScripts XPC call (periodic daily weekly monthly) to async/throwing and returns a result line.

import Foundation
import os.log

/// Runs the system maintenance scripts via the privileged helper.
///
/// The XPC protocol's `runMaintenanceScripts(reply:)` reports only success or
/// failure — `periodic daily weekly monthly` writes its real output to
/// `/var/log/{daily,weekly,monthly}.out`, not stdout, and the selector is
/// frozen (pinned by `HelperProtocolTests`). So `run()` returns a
/// human-readable *result line* for the UI's output log rather than the
/// scripts' stdout.
struct MaintenanceScriptRunner {

    typealias HelperProvider = @Sendable (@escaping @Sendable (Error) -> Void) -> VaderCleanerHelperProtocol?

    private let helperProvider: HelperProvider
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "MaintenanceScriptRunner")

    init(helperProvider: @escaping HelperProvider = SystemJunkDeleter.defaultHelperProvider) {
        self.helperProvider = helperProvider
    }

    /// Asks the helper to run the maintenance scripts. See `HelperCall` for
    /// the dual reply/error paths and the watchdog that keep a dropped or
    /// wedged connection from freezing the UI. Returns a result line on
    /// success; throws on any failure (including an unreachable helper).
    func run() async throws -> String {
        let error = await HelperCall.perform(helperProvider: helperProvider) { helper, reply in
            helper.runMaintenanceScripts(reply: reply)
        }
        if let error {
            log.error("Maintenance scripts failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
        return String(
            localized: "Ran maintenance scripts: periodic daily weekly monthly. Detailed output is written to /var/log/daily.out, /var/log/weekly.out, and /var/log/monthly.out.",
            comment: "Result line shown after the system maintenance scripts complete."
        )
    }
}
