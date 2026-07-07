// ScanProgressIndicatorTests.swift
// Pins the scan indicator's hero sizing: the default diameter every loading screen shares.

import XCTest
@testable import VaderCleaner

final class ScanProgressIndicatorTests: XCTestCase {

    func testDefaultDiameterIsTheSharedHeroSize() {
        // Every scan/clean loading screen builds `ScanProgressIndicator()`
        // with no explicit size, so this default is the single knob for how
        // large the loader reads app-wide. Pinned so a stray per-screen
        // override or an accidental default change can't quietly shrink the
        // hero treatment back down.
        XCTAssertEqual(ScanProgressIndicator().size, 220)
    }
}
