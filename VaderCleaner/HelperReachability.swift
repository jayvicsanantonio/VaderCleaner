// HelperReachability.swift
// Probes whether the privileged helper actually answers, so a registration that reads as enabled can't be reported healthy while every privileged call fails.

import Foundation

/// Asks the helper a question with no side effects and reports whether it
/// answered.
///
/// `SMAppService` status alone is not evidence the helper works: a rebuilt
/// helper binary leaves the approval record in place while the service itself is
/// gone, so the status reads `.enabled` and every call fails with an
/// `NSXPCConnection` lookup error. Only a round trip distinguishes the two.
///
/// The probe is `deleteFiles([])` — an empty batch, which the helper's deletion
/// policy walks and finishes without touching anything. Reusing an existing
/// selector keeps this off the XPC protocol, which both targets and every test
/// spy would otherwise have to grow.
struct HelperReachability: Sendable {

    private let runner: PrivilegedTaskRunner

    init(helperProvider: @escaping PrivilegedTaskRunner.HelperProvider = SystemJunkDeleter.defaultHelperProvider) {
        runner = PrivilegedTaskRunner(
            helperProvider: helperProvider,
            invoke: { helper, done in helper.deleteFiles([], reply: done) },
            // Nothing reads a success line from a probe.
            successMessage: ""
        )
    }

    /// True when the helper answered. An error it reports itself still counts as
    /// reachable — the connection carried it — so only connection-class
    /// failures read as unreachable.
    func probe() async -> Bool {
        do {
            _ = try await runner.run()
            return true
        } catch {
            return !HelperConnectionError.isConnectionFailure(error)
        }
    }
}
