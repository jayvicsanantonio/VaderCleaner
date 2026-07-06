// ScanActivityAssertion.swift
// Holds an idle-sleep-preventing power assertion around an async scan so an automatic system sleep doesn't suspend a scan that is still running.

import Foundation

/// Runs an async operation while holding a `ProcessInfo` activity that keeps the
/// system awake, releasing the activity once the work finishes — including when
/// the work suspends repeatedly or the task is cancelled.
///
/// The `begin`/`end` seams default to `ProcessInfo.beginActivity`/`endActivity`
/// but are injectable so tests can verify the activity is taken for the whole
/// duration of the work and always released, without a real power assertion.
@MainActor
struct ScanActivityAssertion {
    /// Starts a system activity and returns an opaque token identifying it.
    private let begin: (String) -> NSObjectProtocol
    /// Releases the activity identified by a token previously returned by `begin`.
    private let end: (NSObjectProtocol) -> Void

    init(
        begin: @escaping (String) -> NSObjectProtocol = { reason in
            ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: reason
            )
        },
        end: @escaping (NSObjectProtocol) -> Void = { token in
            ProcessInfo.processInfo.endActivity(token)
        }
    ) {
        self.begin = begin
        self.end = end
    }

    /// Runs `operation` with the activity held for its full duration. `defer`
    /// guarantees the activity is released even if `operation` returns early.
    func callAsFunction(reason: String, _ operation: () async -> Void) async {
        let token = begin(reason)
        defer { end(token) }
        await operation()
    }
}
