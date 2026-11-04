// SmartScanFreshScanRequestTests.swift
// Tests which Smart Scan phases a request from elsewhere in the app (the Health Monitor's Free Up Space) starts a fresh scan from, and which it only reveals.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite struct SmartScanFreshScanRequestTests {

    private nonisolated static let plan = CarePlan(
        findings: [],
        health: nil,
        unitOutcomes: [:],
        startedAt: Date(timeIntervalSinceReferenceDate: 0),
        finishedAt: Date(timeIntervalSinceReferenceDate: 30)
    )

    /// Nothing to show, an old receipt, or a failure: a fresh scan is what
    /// the person asked for.
    /// `Phase` isn't `Sendable`, so it can't be a test argument; each case is
    /// checked in turn and reported by name instead.
    @Test func aRequestScansWhenThereIsNothingToReview() {
        let phases: [SmartScanViewModel.Phase] = [
            .idle,
            .done(receipt: CareReceipt(date: Date(timeIntervalSinceReferenceDate: 60), lines: [])),
            .failed(message: "The scan couldn't finish."),
        ]
        for phase in phases {
            #expect(phase.startsFreshScanOnRequest, "\(phase)")
        }
    }

    /// A scan under way, a plan waiting for review, or a run in progress is
    /// shown as it is: scanning again would throw away the plan and its picks.
    @Test func aRequestLeavesWorkInProgressAlone() {
        let phases: [SmartScanViewModel.Phase] = [.scanning, .results(Self.plan), .running]
        for phase in phases {
            #expect(!phase.startsFreshScanOnRequest, "\(phase)")
        }
    }
}
