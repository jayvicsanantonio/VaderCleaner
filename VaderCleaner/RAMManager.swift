// RAMManager.swift
// Bridges the privileged flushInactiveMemory XPC call (which runs /usr/sbin/purge) to async/throwing for the Performance feature.

import Foundation
import os.log

/// Frees inactive memory by asking the privileged helper to run `purge`.
struct RAMManager {

    typealias HelperProvider = @Sendable (@escaping @Sendable (Error) -> Void) -> VaderCleanerHelperProtocol?

    private let helperProvider: HelperProvider
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "RAMManager")

    init(helperProvider: @escaping HelperProvider = SystemJunkDeleter.defaultHelperProvider) {
        self.helperProvider = helperProvider
    }

    /// Asks the helper to flush inactive memory. See `HelperCall` for the
    /// dual reply/error paths and the watchdog that keep a dropped or wedged
    /// connection from freezing the UI. Throws on any failure (including an
    /// unreachable helper).
    func flush() async throws {
        let error = await HelperCall.perform(helperProvider: helperProvider) { helper, reply in
            helper.flushInactiveMemory(reply: reply)
        }
        if let error {
            log.error("RAM flush failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }
}
