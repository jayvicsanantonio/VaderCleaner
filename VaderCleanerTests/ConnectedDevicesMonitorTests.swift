// ConnectedDevicesMonitorTests.swift
// Pins the rule for which mounted volumes belong in the menu's Connected Devices tile.

import Testing
@testable import VaderCleaner

@MainActor
@Suite
struct ConnectedDevicesMonitorTests {

    /// A removable or ejectable external volume is listed; the internal boot
    /// disk and ordinary internal volumes are not.
    @Test
    func shouldList_onlyExternalEjectableVolumes() {
        // External thumb drive: removable + ejectable, not internal.
        #expect(ConnectedDevicesMonitor.shouldList(isEjectable: true, isRemovable: true, isInternal: false))
        // External SSD: ejectable, not removable, not internal.
        #expect(ConnectedDevicesMonitor.shouldList(isEjectable: true, isRemovable: false, isInternal: false))
        // Internal boot disk: never listed even if flagged ejectable.
        #expect(!ConnectedDevicesMonitor.shouldList(isEjectable: true, isRemovable: true, isInternal: true))
        // Plain internal volume: not user-ejectable.
        #expect(!ConnectedDevicesMonitor.shouldList(isEjectable: false, isRemovable: false, isInternal: true))
    }
}
