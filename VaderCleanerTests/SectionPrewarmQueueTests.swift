// SectionPrewarmQueueTests.swift
// Verifies the post-Smart-Scan prewarm runs its section scans one at a time, re-checks each section right before starting it, and holds a single activity assertion across the whole sequence.

import XCTest
@testable import VaderCleaner

@MainActor
final class SectionPrewarmQueueTests: XCTestCase {

    /// Records begin/end calls so a test can assert the sequence takes one
    /// activity for all of its steps without taking a real `ProcessInfo` one.
    private final class ActivityLog {
        private(set) var beganReasons: [String] = []
        private(set) var endedCount = 0
        let token = NSObject()

        func begin(_ reason: String) -> NSObjectProtocol {
            beganReasons.append(reason)
            return token
        }

        func end(_ token: NSObjectProtocol) {
            endedCount += 1
        }
    }

    private func queue(_ log: ActivityLog) -> SectionPrewarmQueue {
        SectionPrewarmQueue(activity: ScanActivityAssertion(begin: log.begin, end: log.end))
    }

    // MARK: - One at a time

    func test_drain_runsStepsInOrderWithoutOverlapping() async {
        let log = ActivityLog()
        var events: [String] = []
        var inFlight = 0
        var peakInFlight = 0

        func step(_ name: String) -> SectionPrewarmQueue.Step {
            SectionPrewarmQueue.Step(isPending: { true }) {
                inFlight += 1
                peakInFlight = max(peakInFlight, inFlight)
                events.append("start-\(name)")
                // Suspending mid-step is what would let a concurrent sequence
                // interleave, so the serialisation claim is only meaningful
                // across an await.
                await Task.yield()
                events.append("end-\(name)")
                inFlight -= 1
            }
        }

        await queue(log).drain([step("a"), step("b"), step("c")])

        XCTAssertEqual(events, ["start-a", "end-a", "start-b", "end-b", "start-c", "end-c"])
        XCTAssertEqual(peakInFlight, 1, "prewarm steps must never run concurrently")
    }

    // MARK: - Freshness

    func test_drain_skipsAStepThatStopsBeingPendingWhileAnEarlierStepRuns() async {
        let log = ActivityLog()
        var secondIsPending = true
        var ran: [String] = []

        let first = SectionPrewarmQueue.Step(isPending: { true }) {
            // Stands in for the user scanning that section by hand while the
            // queue is busy with an earlier one.
            secondIsPending = false
            ran.append("first")
        }
        let second = SectionPrewarmQueue.Step(isPending: { secondIsPending }) {
            ran.append("second")
        }

        await queue(log).drain([first, second])

        XCTAssertEqual(ran, ["first"], "a section that stopped being idle must not be re-scanned")
    }

    func test_drain_skipsAStepThatWasNeverPending() async {
        let log = ActivityLog()
        var ran: [String] = []

        await queue(log).drain([
            SectionPrewarmQueue.Step(isPending: { false }) { ran.append("skipped") },
            SectionPrewarmQueue.Step(isPending: { true }) { ran.append("ran") }
        ])

        XCTAssertEqual(ran, ["ran"])
    }

    // MARK: - Re-entrancy

    func test_drain_ignoresASecondSequenceWhileOneIsAlreadyRunning() async {
        let log = ActivityLog()
        let subject = queue(log)
        let ran = TestBox<[String]>([])

        // Stands in for a second Smart Scan completing while the prewarm from
        // the first is still working through its sections.
        let second = SectionPrewarmQueue.Step(isPending: { true }) {
            ran.value.append("second")
        }
        let first = SectionPrewarmQueue.Step(isPending: { true }) {
            await subject.drain([second])
            ran.value.append("first")
        }

        await subject.drain([first])

        XCTAssertEqual(ran.value, ["first"], "a second completion must not start a competing prewarm sequence")
        XCTAssertEqual(log.beganReasons.count, 1, "the dropped sequence must not take its own activity assertion")
    }

    func test_drain_runsAgainOnceThePreviousSequenceHasFinished() async {
        let log = ActivityLog()
        let subject = queue(log)
        var ran: [String] = []

        await subject.drain([SectionPrewarmQueue.Step(isPending: { true }) { ran.append("first") }])
        await subject.drain([SectionPrewarmQueue.Step(isPending: { true }) { ran.append("second") }])

        XCTAssertEqual(ran, ["first", "second"])
    }

    // MARK: - Activity assertion

    func test_drain_holdsOneActivityAcrossTheWholeSequenceThenReleasesIt() async {
        let log = ActivityLog()
        var beganDuringSteps: [Int] = []
        var endedDuringSteps: [Int] = []

        func step() -> SectionPrewarmQueue.Step {
            SectionPrewarmQueue.Step(isPending: { true }) {
                beganDuringSteps.append(log.beganReasons.count)
                endedDuringSteps.append(log.endedCount)
            }
        }

        await queue(log).drain([step(), step()])

        XCTAssertEqual(beganDuringSteps, [1, 1], "one assertion must cover every step, not one per step")
        XCTAssertEqual(endedDuringSteps, [0, 0], "the assertion must stay held until the last step finishes")
        XCTAssertEqual(log.endedCount, 1, "the assertion must be released when the sequence finishes")
    }

    func test_drain_releasesTheActivityWhenThereIsNothingToDo() async {
        let log = ActivityLog()

        await queue(log).drain([SectionPrewarmQueue.Step(isPending: { false }) {}])

        XCTAssertEqual(log.beganReasons.count, 1)
        XCTAssertEqual(log.endedCount, 1)
    }
}
