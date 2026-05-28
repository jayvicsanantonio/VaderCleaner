// ObservationRecording.swift
// Test helpers for `@Observable` types: captures every value of a tracked key path while work runs, and polls a condition with a timeout — the @Observable equivalents of `vm.$phase.sink { … }` and `XCTestExpectation` fulfilment.

import Foundation
import Observation
import XCTest

/// Records the value at `keyPath` on `subject` at the moment this call starts,
/// then every time the property changes while `work()` runs. Returns the
/// captured sequence with the initial value as element 0.
///
/// `withObservationTracking`'s `onChange` fires exactly once per registration,
/// so a continuous recording requires re-arming after every change. This
/// helper hides that bookkeeping so individual tests read like the older
/// `let cancellable = vm.$phase.sink { phases.append($0) }` pattern they
/// replaced.
///
/// The final `await Task.yield()` lets any onChange-spawned main-actor hop
/// land before the recorder stops re-arming — without it, a transition that
/// fires during the very last instant of `work()` could be dropped because
/// the recorder shut down before the appender ran.
///
/// **Known limitation.** The recorder can miss a transition that fires very
/// close to a structured-concurrency suspension in `work()` — empirically,
/// `SystemJunkViewModelTests.test_scan_transitionsIdleToScanningToPreview`
/// hit this with a synchronous-returning `await scanner()` whose terminal
/// `.preview` write landed between the re-arm and the recorder's
/// shutdown. Tests asserting `phases.contains(...)` are robust to this; tests
/// asserting on `phases.last` (the *final* transition) should use the
/// `ScanGate` continuation pattern (`ScanCoordinatingConformanceTests`
/// shows the idiom) instead of this helper.
@MainActor
func recordTransitions<Subject: AnyObject, Value>(
    of keyPath: KeyPath<Subject, Value>,
    on subject: Subject,
    perform work: () async -> Void
) async -> [Value] {
    var captured: [Value] = [subject[keyPath: keyPath]]
    var keepRecording = true

    func arm() {
        guard keepRecording else { return }
        withObservationTracking {
            _ = subject[keyPath: keyPath]
        } onChange: {
            // `onChange` fires synchronously from `willSet`, on whichever
            // actor the mutation happens on. The subjects we record are
            // `@MainActor` view models, so we are already isolated here —
            // append synchronously rather than hopping to a Task, which
            // would defer the append past the caller's next assertion and
            // produce false negatives in tight tests.
            MainActor.assumeIsolated {
                guard keepRecording else { return }
                captured.append(subject[keyPath: keyPath])
                arm()
            }
        }
    }
    arm()

    await work()
    await Task.yield()
    keepRecording = false
    return captured
}

/// Polls `condition` every 20 ms until it returns `true` or `timeout` elapses.
/// Used in place of `XCTestExpectation` + a `@Published` sink when waiting for
/// an `@Observable` property to reach a value — the condition closure runs on
/// the main actor so it can read tracked properties without bouncing actors.
///
/// Calls `XCTFail` (attributed to `file`/`line`) if the timeout elapses
/// without the condition becoming true, so the failure points at the test's
/// own call site rather than this helper.
@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    pollInterval: TimeInterval = 0.02,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    XCTFail("Condition did not become true within \(timeout)s", file: file, line: line)
}
