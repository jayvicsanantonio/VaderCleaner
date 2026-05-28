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
/// `onChange` fires synchronously during the mutation's `willSet`, *before*
/// the new value is committed — so reading the key path inside the closure
/// would capture the value being replaced, not the one that triggered the
/// change. The closure therefore hops to a fresh `@MainActor` `Task`, which
/// runs after the mutation completes, then reads the committed value and
/// re-arms. Re-arming from the Task (rather than inside `onChange`) also keeps
/// us from re-entering `withObservationTracking` from within its own change
/// callback. Everything stays main-actor isolated, so the captures are
/// race-free.
///
/// The trailing `await Task.yield()` calls drain the deferred appends before
/// re-arming stops, so a change that fires in the last instant of `work()` is
/// still captured. A test that depends on the *final* transition landing
/// should still prefer a continuation gate (see the `ScanPhaseGate` idiom in
/// `ScanCoordinatingConformanceTests`); this helper is meant for
/// `phases.contains(...)` / `phases.first` style assertions.
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
            // Defer to a fresh main-actor Task: `onChange` runs in `willSet`,
            // so the read below must wait until the new value is committed.
            Task { @MainActor in
                guard keepRecording else { return }
                captured.append(subject[keyPath: keyPath])
                arm()
            }
        }
    }
    arm()

    await work()
    // Two hops: the first lets a final-change Task enqueue, the second lets it
    // run, before re-arming stops.
    await Task.yield()
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
