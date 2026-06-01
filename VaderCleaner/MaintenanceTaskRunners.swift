// MaintenanceTaskRunners.swift
// Privileged maintenance-task runners — bridges the DNS-flush, Spotlight-reindex, and Time Machine snapshot-thinning XPC calls to async/throwing and returns a human-readable result line for each.

import Foundation
import os.log

/// Shared bridge from a reply-block helper selector to async/throwing. Mirrors
/// `MaintenanceScriptRunner`'s structure but is parameterised by the selector
/// to invoke and the success message to return, so the three privileged
/// maintenance tasks share one connection/continuation path instead of three
/// copies. Collaborators are injected as a `helperProvider` closure so unit
/// tests exercise success / failure / dropped-reply without a live helper.
struct PrivilegedTaskRunner {

    typealias HelperProvider = (@escaping (Error) -> Void) -> VaderCleanerHelperProtocol?
    typealias Invoke = (VaderCleanerHelperProtocol, @escaping (Error?) -> Void) -> Void

    private let helperProvider: HelperProvider
    private let invoke: Invoke
    private let successMessage: String
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "PrivilegedTaskRunner")

    init(
        helperProvider: @escaping HelperProvider,
        invoke: @escaping Invoke,
        successMessage: String
    ) {
        self.helperProvider = helperProvider
        self.invoke = invoke
        self.successMessage = successMessage
    }

    /// Invokes the configured selector. Installs both the per-call XPC error
    /// handler and the reply block so a dropped connection can't freeze the UI.
    /// Returns the success line on success; throws on any failure (including an
    /// unreachable helper).
    func run() async throws -> String {
        let error: Error? = await withCheckedContinuation { continuation in
            let resumer = TaskResumer(continuation: continuation)
            let helper = helperProvider { connectionError in
                resumer.resume(with: connectionError)
            }
            guard let helper else {
                resumer.resume(with: HelperConnectionError.unavailable)
                return
            }
            invoke(helper) { replyError in
                resumer.resume(with: replyError)
            }
        }
        if let error {
            log.error("Maintenance task failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return successMessage
    }
}

/// Once-only continuation resume — the XPC reply block and the connection-level
/// error handler may both fire and `CheckedContinuation` traps on a second
/// resume, so the first wins and later attempts are dropped.
private final class TaskResumer: @unchecked Sendable {
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

// MARK: - DNS cache

/// Flushes the DNS resolver cache through the privileged helper.
struct DNSCacheFlusher {
    private let runner: PrivilegedTaskRunner

    init(helperProvider: @escaping PrivilegedTaskRunner.HelperProvider = SystemJunkDeleter.defaultHelperProvider) {
        runner = PrivilegedTaskRunner(
            helperProvider: helperProvider,
            invoke: { helper, done in helper.flushDNSCache(reply: done) },
            successMessage: String(
                localized: "Flushed the DNS resolver cache.",
                comment: "Result line shown after the DNS cache is flushed."
            )
        )
    }

    func run() async throws -> String { try await runner.run() }
}

// MARK: - Spotlight

/// Erases and rebuilds the Spotlight index for the boot volume.
struct SpotlightReindexer {
    private let runner: PrivilegedTaskRunner

    init(helperProvider: @escaping PrivilegedTaskRunner.HelperProvider = SystemJunkDeleter.defaultHelperProvider) {
        runner = PrivilegedTaskRunner(
            helperProvider: helperProvider,
            invoke: { helper, done in helper.reindexSpotlight(reply: done) },
            successMessage: String(
                localized: "Started rebuilding the Spotlight index. Search may be slower until indexing finishes.",
                comment: "Result line shown after a Spotlight reindex is started."
            )
        )
    }

    func run() async throws -> String { try await runner.run() }
}

// MARK: - Time Machine

/// Thins local Time Machine snapshots on the boot volume.
struct TimeMachineSnapshotThinner {
    private let runner: PrivilegedTaskRunner

    init(helperProvider: @escaping PrivilegedTaskRunner.HelperProvider = SystemJunkDeleter.defaultHelperProvider) {
        runner = PrivilegedTaskRunner(
            helperProvider: helperProvider,
            invoke: { helper, done in helper.thinTimeMachineSnapshots(reply: done) },
            successMessage: String(
                localized: "Thinned local Time Machine snapshots.",
                comment: "Result line shown after local Time Machine snapshots are thinned."
            )
        )
    }

    func run() async throws -> String { try await runner.run() }
}
