// ScanCoordinatingTests.swift
// Pins the coarse scan-state contract: ScanPresentation Equatable behavior and the ScanCoordinating protocol's beginScan() + Observation surface.

import XCTest
import Observation
@testable import VaderCleaner

@MainActor
final class ScanCoordinatingTests: XCTestCase {

    /// Minimal stand-in for the real scannable view models. `@Observable`
    /// satisfies the protocol's get-only `scanPresentation` requirement and
    /// hooks the property into the Observation framework so views (and the
    /// transition recorder below) re-render on mutation. `beginScanCalled`
    /// records that the coordinator's entrypoint ran.
    @Observable
    fileprivate final class FakeCoordinator: ScanCoordinating {
        var scanPresentation: ScanPresentation = .intro
        private(set) var beginScanCalled = false

        func beginScan() {
            beginScanCalled = true
        }
    }

    func test_scanPresentation_equatableDistinguishesAllCases() {
        XCTAssertEqual(ScanPresentation.intro, .intro)
        XCTAssertEqual(ScanPresentation.working, .working)
        XCTAssertEqual(ScanPresentation.results, .results)

        XCTAssertNotEqual(ScanPresentation.intro, .working)
        XCTAssertNotEqual(ScanPresentation.working, .results)
        XCTAssertNotEqual(ScanPresentation.intro, .results)
    }

    func test_beginScan_flipsTheFakesFlag() {
        let fake = FakeCoordinator()
        XCTAssertFalse(fake.beginScanCalled, "Flag must start false")

        fake.beginScan()

        XCTAssertTrue(fake.beginScanCalled, "beginScan() must record that it ran")
    }

    /// Mutating `scanPresentation` must register through the Observation
    /// framework so any observing view (or `withObservationTracking` caller)
    /// is notified. Replaces the older `objectWillChange.sink` assertion
    /// that no longer applies under `@Observable`.
    func test_presentationChange_firesObservationOnChange() {
        let fake = FakeCoordinator()
        var fired = false
        withObservationTracking {
            _ = fake.scanPresentation
        } onChange: {
            fired = true
        }

        fake.scanPresentation = .working

        XCTAssertTrue(
            fired,
            "Mutating scanPresentation must invoke withObservationTracking's onChange"
        )
        XCTAssertEqual(fake.scanPresentation, .working)
    }
}
