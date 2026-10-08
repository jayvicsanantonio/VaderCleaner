// ProcessExitWaitTests.swift
// Runs a thousand short child processes back to back through each of DefaultBrewRunner and ProcessLineStreamer, pinning that every run returns once its child exits rather than waiting on it forever.

import Foundation
import Testing
@testable import VaderCleanerCore

/// Foundation's `Process.waitUntilExit()` can wait forever on a child that has
/// already exited and been reaped, so neither wrapper may rely on it.
///
/// `waitUntilExit()` asks whether the *calling* thread launched the process by
/// looking the object's address up in a per-thread list that is appended to at
/// launch and never pruned. Once a pool thread has launched one process, a
/// later process allocated at the same freed address, but launched from a
/// different thread, is mistaken for that thread's own. With no
/// `terminationHandler` set, the waiter then waits for a termination
/// notification that only the real launching thread's run loop would post —
/// and a Swift concurrency pool thread never runs its run loop.
///
/// A reused address has to meet a reused thread, which can take anywhere from
/// a handful to a few hundred launches from async code, so each test runs a
/// thousand. A run that never returns would take the whole test process down
/// with it if awaited — and `TestHelpers.value(of:within:)` waits for the task
/// it cancels to finish — so the runs are polled instead, and a stuck one
/// fails the test.
@Suite struct ProcessExitWaitTests {

    private let sh = URL(fileURLWithPath: "/bin/sh")

    @Test func everyBrewCaptureReturnsOnceItsChildExits() async throws {
        // `/bin/sh` stands in for `brew`: the runner only needs an executable.
        let runner = DefaultBrewRunner(brewURL: sh)
        try await expectEveryRunReturns {
            let result = try await runner.runCapturing(["-c", "echo out; echo err 1>&2"])
            #expect(result.terminationStatus == 0)
            #expect(result.standardOutput == "out\n")
            #expect(result.standardError == "err\n")
        }
    }

    @Test func everyStreamedRunReturnsOnceItsChildExits() async throws {
        let sh = sh
        try await expectEveryRunReturns {
            let lines = TestBox<[String]>([])
            let status = try await ProcessLineStreamer.run(
                executable: sh,
                arguments: ["-c", "printf 'a\\nb\\n'"],
                onLine: { lines.value.append($0) }
            )
            #expect(status == 0)
            #expect(lines.value == ["a", "b"])
        }
    }

    /// Calls `run` a thousand times in sequence from a separate task, failing —
    /// not hanging — if any one call never returns.
    private func expectEveryRunReturns(
        _ run: @escaping @Sendable () async throws -> Void
    ) async throws {
        let runCount = 1000
        let returned = TestBox(0)
        let finished = TestBox(false)
        let runs = Task {
            defer { finished.value = true }
            for _ in 0..<runCount {
                try await run()
                returned.value += 1
            }
        }
        // Timed on `SuspendingClock` rather than `pollUntil`'s continuous
        // clock: a Mac that sleeps mid-run pauses the runs too, and that time
        // must not count against them. A thousand runs take a few seconds
        // (under ten through xcodebuild, which runs this suite's tests one at
        // a time); the limit only has to tell that apart from a run that never
        // returns.
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while !finished.value, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let completed = finished.value
        #expect(completed, "run \(returned.value + 1) of \(runCount) never returned")
        if completed {
            // Rethrows a launch failure as this test's own error.
            try await runs.value
        }
    }
}
