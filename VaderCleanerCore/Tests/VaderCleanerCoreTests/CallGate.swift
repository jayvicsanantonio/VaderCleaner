// CallGate.swift
// Holds a synchronous test double mid-call until the test opens it, so a test can look at the code under test while that call is still in flight.

import Foundation

/// Blocks a synchronous collaborator — a stand-in for `SMAppService.register()`
/// waiting on launchd — inside `hold()` until the test calls `open()`, and
/// records which thread the call ran on.
///
/// The wait is bounded. A regression that makes the call on the main actor,
/// where the test can never reach `open()`, then fails the test once
/// `timeout` passes instead of hanging the suite. The default is generous on
/// purpose: a hold that ran out early on a slow CI runner would let a correct
/// implementation fail.
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
