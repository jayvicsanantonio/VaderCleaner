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
struct PrivilegedTaskRunner: Sendable {

    typealias HelperProvider = @Sendable (@escaping @Sendable (Error) -> Void) -> VaderCleanerHelperProtocol?
    typealias Invoke = @Sendable (VaderCleanerHelperProtocol, @escaping @Sendable (Error?) -> Void) -> Void

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

    /// Invokes the configured selector. See `HelperCall` for the dual
    /// reply/error paths and the watchdog that keep a dropped or wedged
    /// connection from freezing the UI. Returns the success line on success;
    /// throws on any failure (including an unreachable helper).
    ///
    /// The Spotlight reindex is the call most likely to need the watchdog:
    /// `mdutil -E /` is the longest-running of the three.
    func run() async throws -> String {
        let error = await HelperCall.perform(helperProvider: helperProvider, invoke)
        if let error {
            log.error("Maintenance task failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
        return successMessage
    }
}

// MARK: - DNS cache

/// Flushes the DNS resolver cache through the privileged helper.
struct DNSCacheFlusher: Sendable {
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
struct SpotlightReindexer: Sendable {
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
struct TimeMachineSnapshotThinner: Sendable {
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
