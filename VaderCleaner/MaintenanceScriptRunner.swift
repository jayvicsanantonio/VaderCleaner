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

    typealias HelperProvider = (@escaping (Error) -> Void) -> VaderCleanerHelperProtocol?

    private let helperProvider: HelperProvider
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "MaintenanceScriptRunner")

    init(helperProvider: @escaping HelperProvider = SystemJunkDeleter.defaultHelperProvider) {
        self.helperProvider = helperProvider
    }

    /// Asks the helper to run the maintenance scripts. Installs both the
    /// per-call XPC error handler and the reply block so a dropped connection
    /// can't freeze the UI. Returns a result line on success; throws on any
    /// failure (including an unreachable helper).
    func run() async throws -> String {
        let error: Error? = await withCheckedContinuation { continuation in
            let resumer = MaintenanceResumer(continuation: continuation)
            let helper = helperProvider { connectionError in
                resumer.resume(with: connectionError)
            }
            guard let helper else {
                resumer.resume(with: NSError(
                    domain: "com.personal.VaderCleaner.MaintenanceScriptRunner",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Helper unavailable"]
                ))
                return
            }
            helper.runMaintenanceScripts { replyError in
                resumer.resume(with: replyError)
            }
        }
        if let error {
            log.error("Maintenance scripts failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return String(
            localized: "Ran maintenance scripts: periodic daily weekly monthly. Detailed output is written to /var/log/daily.out, /var/log/weekly.out, and /var/log/monthly.out.",
            comment: "Result line shown after the system maintenance scripts complete."
        )
    }
}

/// Once-only continuation resume — see `SystemJunkDeleter.Resumer`. Both the
/// XPC reply block and the connection error handler may fire and
/// `CheckedContinuation` traps on a second resume.
private final class MaintenanceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?

    init(continuation: CheckedContinuation<Error?, Never>) {
        self.continuation = continuation
    }

    func resume(with error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: error)
    }
}
