// AppStateTests.swift
// Tests that AppState exposes the FDA flag and refreshes it from its injected checker.

import XCTest
@testable import VaderCleaner

final class AppStateTests: XCTestCase {

    func test_init_setsHasFullDiskAccess_fromInjectedChecker_whenTrue() {
        let sut = AppState(checker: { true })
        XCTAssertTrue(sut.hasFullDiskAccess)
    }

    func test_init_setsHasFullDiskAccess_fromInjectedChecker_whenFalse() {
        let sut = AppState(checker: { false })
        XCTAssertFalse(sut.hasFullDiskAccess)
    }

    func test_refresh_pullsUpdatedValueFromChecker() {
        var current = false
        let sut = AppState(checker: { current })
        XCTAssertFalse(sut.hasFullDiskAccess)
        current = true
        sut.refresh()
        XCTAssertTrue(sut.hasFullDiskAccess)
    }

    func test_refresh_pullsUpdatedValueFromChecker_whenRevoked() {
        var current = true
        let sut = AppState(checker: { current })
        XCTAssertTrue(sut.hasFullDiskAccess)
        current = false
        sut.refresh()
        XCTAssertFalse(sut.hasFullDiskAccess)
    }
}
