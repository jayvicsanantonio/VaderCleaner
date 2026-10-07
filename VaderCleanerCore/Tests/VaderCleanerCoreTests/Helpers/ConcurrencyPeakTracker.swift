// ConcurrencyPeakTracker.swift
// Records how many of its enter()/exit() pairs were ever open at once, so a test can prove a supposedly-serial loop never overlaps itself.

/// Serializes `enter`/`exit` bookkeeping through actor isolation so concurrent
/// callers can't race the active count the way the code under test might.
actor ConcurrencyPeakTracker {
    private var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func exit() {
        active -= 1
    }
}
