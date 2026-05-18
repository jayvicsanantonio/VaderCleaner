// ScanCoordinatingTests.swift
// Pins the coarse scan-state contract: ScanPresentation Equatable behavior and the ScanCoordinating protocol's beginScan() + observability surface.

import XCTest
import Combine
@testable import VaderCleaner

final class ScanCoordinatingTests: XCTestCase {

    /// Minimal stand-in for the real scannable view models (which conform in a
    /// later step). `@Published` satisfies the protocol's get-only
    /// `scanPresentation` requirement and gives `objectWillChange` for free;
    /// `beginScanCalled` records that the coordinator's entrypoint ran.
    private final class FakeCoordinator: ScanCoordinating {
        @Published var scanPresentation: ScanPresentation = .intro
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

    func test_presentationChange_isObservableViaObjectWillChange() {
        let fake = FakeCoordinator()
        var fired = false
        let cancellable = fake.objectWillChange.sink { _ in fired = true }

        fake.scanPresentation = .working

        withExtendedLifetime(cancellable) {
            XCTAssertTrue(
                fired,
                "Mutating scanPresentation must publish through objectWillChange"
            )
        }
        XCTAssertEqual(fake.scanPresentation, .working)
    }
}
