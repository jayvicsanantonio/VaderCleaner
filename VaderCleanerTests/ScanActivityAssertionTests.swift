// ScanActivityAssertionTests.swift
// Verifies ScanActivityAssertion holds a system activity for the full duration of an async scan and always releases it, so idle sleep can't suspend a running scan.

import XCTest
@testable import VaderCleaner

@MainActor
final class ScanActivityAssertionTests: XCTestCase {

    /// Records begin/end calls so a test can assert on ordering and the token
    /// round-trip without taking a real `ProcessInfo` activity.
    private final class ActivityLog {
        private(set) var beganReasons: [String] = []
        private(set) var endedTokens: [ObjectIdentifier] = []
        let token = NSObject()

        func begin(_ reason: String) -> NSObjectProtocol {
            beganReasons.append(reason)
            return token
        }

        func end(_ token: NSObjectProtocol) {
            endedTokens.append(ObjectIdentifier(token))
        }
    }

    func test_holdsActivityForDurationOfOperationThenReleasesIt() async {
        let log = ActivityLog()
        let assertion = ScanActivityAssertion(begin: log.begin, end: log.end)

        var beganCountDuringOperation = 0
        var endedCountDuringOperation = 0
        await assertion(reason: "scan") {
            beganCountDuringOperation = log.beganReasons.count
            endedCountDuringOperation = log.endedTokens.count
        }

        XCTAssertEqual(beganCountDuringOperation, 1, "activity must be held before the operation runs")
        XCTAssertEqual(endedCountDuringOperation, 0, "activity must stay held while the operation runs")
        XCTAssertEqual(log.endedTokens.count, 1, "activity must be released once the operation finishes")
        XCTAssertEqual(log.endedTokens.first, ObjectIdentifier(log.token), "the token from begin must be the one released")
        XCTAssertEqual(log.beganReasons, ["scan"], "the reason must be forwarded to begin")
    }

    func test_releasesActivityEvenWhenOperationSuspends() async {
        let log = ActivityLog()
        let assertion = ScanActivityAssertion(begin: log.begin, end: log.end)

        await assertion(reason: "scan") {
            await Task.yield() // the real scans suspend repeatedly; the assertion must survive that
        }

        XCTAssertEqual(log.beganReasons.count, 1)
        XCTAssertEqual(log.endedTokens.count, 1, "a suspending operation must still release the activity exactly once")
    }
}
