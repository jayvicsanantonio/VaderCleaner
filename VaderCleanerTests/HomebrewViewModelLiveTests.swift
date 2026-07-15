// HomebrewViewModelLiveTests.swift
// Verifies HomebrewViewModel.live() composes without touching real brew.

import XCTest
@testable import VaderCleaner

@MainActor
final class HomebrewViewModelLiveTests: XCTestCase {

    /// `.live()` must construct cleanly. It starts in `.idle` and only touches
    /// the filesystem/brew on an explicit `load()`, so building it is inert.
    func test_live_constructsInIdle() {
        let vm = HomebrewViewModel.live()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.inventory.isEmpty)
        XCTAssertEqual(vm.availableUpdateCount, 0)
    }
}
