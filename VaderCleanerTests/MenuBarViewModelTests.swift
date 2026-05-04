// MenuBarViewModelTests.swift
// Tests that MenuBarViewModel exposes non-empty placeholder strings the menu bar label can render.

import XCTest
@testable import VaderCleaner

@MainActor
final class MenuBarViewModelTests: XCTestCase {

    func test_init_setsDefaultStatValues() {
        let sut = MenuBarViewModel()
        // The menu bar label is built from these strings on launch — both must be
        // populated before any real telemetry wires up in Prompt 10.
        XCTAssertFalse(sut.formattedRAMUsage.isEmpty)
        XCTAssertFalse(sut.formattedDiskSpace.isEmpty)
    }

    func test_formattedRAMUsage_isNonEmptyString() {
        let sut = MenuBarViewModel()
        XCTAssertFalse(sut.formattedRAMUsage.isEmpty)
    }

    func test_formattedDiskSpace_isNonEmptyString() {
        let sut = MenuBarViewModel()
        XCTAssertFalse(sut.formattedDiskSpace.isEmpty)
    }
}
