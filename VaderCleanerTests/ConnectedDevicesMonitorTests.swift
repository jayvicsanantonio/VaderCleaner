// ConnectedDevicesMonitorTests.swift
// Pins the rule for which mounted volumes belong in the menu's Connected Devices tile.

import XCTest
@testable import VaderCleaner

@MainActor
final class ConnectedDevicesMonitorTests: XCTestCase {

    /// A removable or ejectable external volume is listed; the internal boot
    /// disk and ordinary internal volumes are not.
    func test_shouldList_onlyExternalEjectableVolumes() {
        // External thumb drive: removable + ejectable, not internal.
        XCTAssertTrue(ConnectedDevicesMonitor.shouldList(isEjectable: true, isRemovable: true, isInternal: false))
        // External SSD: ejectable, not removable, not internal.
        XCTAssertTrue(ConnectedDevicesMonitor.shouldList(isEjectable: true, isRemovable: false, isInternal: false))
        // Internal boot disk: never listed even if flagged ejectable.
        XCTAssertFalse(ConnectedDevicesMonitor.shouldList(isEjectable: true, isRemovable: true, isInternal: true))
        // Plain internal volume: not user-ejectable.
        XCTAssertFalse(ConnectedDevicesMonitor.shouldList(isEjectable: false, isRemovable: false, isInternal: true))
    }
}
