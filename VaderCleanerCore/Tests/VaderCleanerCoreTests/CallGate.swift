// CallGate.swift
// Holds a test double mid-call until the test opens it, so a test can look at the code under test while that call is still in flight.

import Foundation
import Synchronization

/// Blocks a synchronous collaborator — a stand-in for `SMAppService.register()`
/// waiting on launchd — inside `hold()` until the test calls `open()`, and
/// records which thread the call ran on.
///
/// The wait is bounded. A regression that makes the call on the main actor,
/// where the test can never reach `open()`, then fails the test once
/// `timeout` passes instead of hanging the suite. The default is generous on
/// purpose: a hold that ran out early on a slow CI runner would let a correct
/// implementation fail.
///
/// A held call occupies a cooperative pool thread for its whole wait, and CI's
/// runners have only a few. `pollUntil` needs one of them to wake up, so enough
/// holds at once stop every test from reaching `open()` until the holds time
/// out. Keep this for collaborators that really are synchronous; an async double
/// uses `SuspendingCallGate`.
final class CallGate: Sendable {

    private let release = DispatchSemaphore(value: 0)
    private let timeout: DispatchTimeInterval
    private let holding = TestBox(false)
    private let ranOnMainThread = TestBox<Bool?>(nil)

    init(timeout: DispatchTimeInterval = .seconds(10)) {
        self.timeout = timeout
    }

    /// Whether a call is blocked inside `hold()` right now.
    var isHolding: Bool { holding.value }

    /// Whether the most recent held call ran on the main thread; `nil` until
    /// one has.
    var heldOnMainThread: Bool? { ranOnMainThread.value }

    /// Called from inside the test double: blocks until `open()`.
    func hold() {
        ranOnMainThread.value = Thread.isMainThread
        holding.value = true
        _ = release.wait(timeout: .now() + timeout)
        holding.value = false
    }

    /// Lets the held call return.
    func open() {
        release.signal()
    }
}

/// Holds an async test double mid-call until the test opens it, suspending rather
/// than blocking so a held call costs no pool thread. Opening is permanent: a
/// later call passes straight through.
final class SuspendingCallGate: Sendable {

    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Whether a call is suspended inside `hold()` right now.
    var isHolding: Bool { state.withLock { !$0.waiters.isEmpty } }

    /// Called from inside the test double: suspends until `open()`.
    func hold() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    /// Lets every held call return, along with any made from now on.
    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
