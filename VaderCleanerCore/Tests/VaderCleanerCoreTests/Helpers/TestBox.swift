// TestBox.swift
// Lock-guarded mutable slot so `@Sendable` test doubles can record calls, which a captured local `var` cannot do under the Swift 6 language mode.

import Foundation

/// A mutable slot a `@Sendable` closure can capture.
///
/// The production collaborator closures are `@Sendable` because the scanners
/// invoke them from detached tasks, which means a test double can no longer
/// capture a plain local `var` to count calls. This box is the reference-typed
/// stand-in: `let calls = TestBox(0)` then `calls.value += 1`.
///
/// `@unchecked Sendable` is sound because the slot is guarded by a lock, so
/// concurrent recording from a scan task and reading from the test body are
/// both safe.
final class TestBox<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    /// Runs `body` against the value under a single lock acquisition.
    ///
    /// `value.append(_:)` is a separate get and set, so two threads doing it at
    /// once can lose one of the appends. A read-modify-write that has to be
    /// atomic — appending to a log and reading back its new length, say — goes
    /// through here instead.
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&storage) }
    }
}
