// SystemStatsDeviceHealthTests.swift
// Tests that the slow device-health readings (FileVault, SMART, Apple's battery report) arrive as soon as something starts watching stats, not five minutes later.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite struct SystemStatsDeviceHealthTests {

    /// The app builds its service with `autostart: false` and starts polling
    /// through `beginUpdates()`. The first slow read used to run only from the
    /// autostart path, so every launch showed FileVault, the drive, and the
    /// battery condition as unknown until the five-minute timer fired.
    /// `fdesetup status` answers on every Mac, so FileVault is the probe.
    @Test func beginUpdatesReadsDeviceHealthRightAway() async {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        defer { service.endUpdates() }

        service.beginUpdates()

        #expect(await pollUntil(timeout: .seconds(10)) { service.fileVaultState != .unknown })
    }
}
