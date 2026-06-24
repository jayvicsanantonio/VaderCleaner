// RAMManager.swift
// Bridges the privileged flushInactiveMemory XPC call (which runs /usr/sbin/purge) to async/throwing for the Performance feature.

import Foundation
import os.log

/// Frees inactive memory by asking the privileged helper to run `purge`.
struct RAMManager {

    typealias HelperProvider = (@escaping (Error) -> Void) -> VaderCleanerHelperProtocol?

    private let helperProvider: HelperProvider
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "RAMManager")

    init(helperProvider: @escaping HelperProvider = SystemJunkDeleter.defaultHelperProvider) {
        self.helperProvider = helperProvider
    }

    /// Asks the helper to flush inactive memory. Installs both the per-call
    /// XPC error handler and the reply block so a dropped connection can't
    /// freeze the UI — whichever resolves first wins via the once-only
    /// `Resumer`. Throws on any failure (including an unreachable helper).
    func flush() async throws {
        let error: Error? = await withCheckedContinuation { continuation in
            let resumer = RAMResumer(continuation: continuation)
            let helper = helperProvider { connectionError in
                resumer.resume(with: connectionError)
            }
            guard let helper else {
                resumer.resume(with: HelperConnectionError.unavailable)
                return
            }
            helper.flushInactiveMemory { replyError in
                resumer.resume(with: replyError)
            }
        }
        if let error {
            log.error("RAM flush failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// Once-only continuation resume — see `SystemJunkDeleter.Resumer` for the
/// rationale; both the XPC reply block and the connection error handler may
/// fire and `CheckedContinuation` traps on a second resume.
private final class RAMResumer: @unchecked Sendable {
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
