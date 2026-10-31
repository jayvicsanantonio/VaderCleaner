// HelperToolRunner.swift
// Runs the system tools behind the helper's maintenance calls: one run of a tool at a time, and none able to hold the helper up forever. Compiled into both the core and the helper, so it can't use Bundle.module.

import Foundation
import Synchronization

/// Where the helper reports its own failures, as opposed to the connection to
/// it failing.
enum HelperErrorDomain {
    /// The domain of an error from a system tool the helper ran.
    static let tool = "com.personal.VaderCleaner.helper"
    /// The domain of a refusal because an earlier run of the tool is still going.
    /// Separate from `tool` so its code can't be mistaken for a tool's exit status.
    static let conflict = "com.personal.VaderCleaner.helper.conflict"
}

/// The executables with a run in flight. The app's watchdog gives up on a call
/// while the tool is still going, so retrying from the app must not start a
/// second `mdutil -E` or `periodic` beside the first.
final class RunningExecutables: Sendable {
    private let running = Mutex<Set<String>>([])

    /// Marks `executables` as running, or returns false if any already is.
    func claim(_ executables: [String]) -> Bool {
        running.withLock { running in
            guard running.isDisjoint(with: executables) else { return false }
            running.formUnion(executables)
            return true
        }
    }

    func release(_ executables: [String]) {
        running.withLock { $0.subtract(executables) }
    }
}

enum HelperToolRunner {

    /// How long a tool may run. Just past `HelperCall.defaultTimeout`, so the app
    /// has already stopped waiting by the time a tool is killed. A wedged tool
    /// would otherwise keep its claim in `RunningExecutables` and refuse every
    /// retry until the helper restarted.
    static let defaultTimeout: DispatchTimeInterval = .seconds(660)
    /// How long a tool gets to exit after each signal.
    static let defaultTerminationGrace: DispatchTimeInterval = .seconds(5)

    /// Runs one command to completion and returns its failure, if any. Past
    /// `timeout` the tool gets SIGTERM, then SIGKILL.
    ///
    /// Synchronous on purpose: callers have already hopped onto their work queue,
    /// and running commands in sequence depends on this returning only once the
    /// command is actually done. It waits on `terminationHandler`, set before
    /// `run()`, because `waitUntilExit()` has no timeout.
    static func execute(
        executable: String,
        arguments: [String],
        timeout: DispatchTimeInterval = defaultTimeout,
        terminationGrace: DispatchTimeInterval = defaultTerminationGrace
    ) -> Error? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return error
        }
        guard exited.wait(timeout: .now() + timeout) == .timedOut else {
            guard process.terminationStatus == 0 else {
                return NSError(
                    domain: HelperErrorDomain.tool,
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "\(executable) exited with status \(process.terminationStatus)"]
                )
            }
            return nil
        }
        process.terminate()
        if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + terminationGrace)
        }
        return NSError(
            domain: HelperErrorDomain.tool,
            code: Int(ETIMEDOUT),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) was stopped after running too long"]
        )
    }

    /// The refusal for a tool `RunningExecutables` says is still running.
    static func alreadyRunningError(_ executables: [String]) -> Error {
        NSError(
            domain: HelperErrorDomain.conflict,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(executables.joined(separator: ", ")) is already running"]
        )
    }
}
