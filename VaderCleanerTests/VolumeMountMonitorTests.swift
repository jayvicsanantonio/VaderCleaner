// VolumeMountMonitorTests.swift
// Verifies drive-connected and overfilled-drive dispatch rules against injected volume info.

import XCTest
@testable import VaderCleaner

@MainActor
final class VolumeMountMonitorTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.VolumeMount.\(UUID().uuidString)")!
        preferences = PreferencesStore(defaults: defaults)
        dispatcher = StubNotificationDispatcher()
    }

    private func makeMonitor(_ info: MountedVolumeInfo?) -> VolumeMountMonitor {
        VolumeMountMonitor(
            preferences: preferences,
            dispatcher: dispatcher,
            volumeReader: { _ in info },
            overfilledFreeFraction: 0.10
        )
    }

    private let anyURL = URL(fileURLWithPath: "/Volumes/USB")

    func test_driveConnected_firesWhenToggleOn() {
        preferences.notifyDriveConnected = true
        preferences.notifyOverfilledDrives = false
        let monitor = makeMonitor(MountedVolumeInfo(name: "USB", isExternal: true, freeBytes: 500, totalBytes: 1000))

        monitor.evaluate(mountedVolume: anyURL)

        XCTAssertEqual(dispatcher.calls, [.driveConnected(volumeName: "USB")])
    }

    func test_overfilled_firesForNearlyFullExternalVolume() {
        preferences.notifyDriveConnected = false
        preferences.notifyOverfilledDrives = true
        let monitor = makeMonitor(MountedVolumeInfo(name: "USB", isExternal: true, freeBytes: 50, totalBytes: 1000))

        monitor.evaluate(mountedVolume: anyURL)

        XCTAssertEqual(dispatcher.calls, [.overfilledDrive(volumeName: "USB", freeBytes: 50, totalBytes: 1000)])
    }

    func test_overfilled_doesNotFireForInternalVolume() {
        preferences.notifyDriveConnected = false
        preferences.notifyOverfilledDrives = true
        let monitor = makeMonitor(MountedVolumeInfo(name: "Macintosh HD", isExternal: false, freeBytes: 10, totalBytes: 1000))

        monitor.evaluate(mountedVolume: anyURL)

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_overfilled_doesNotFireWhenEnoughFree() {
        preferences.notifyDriveConnected = false
        preferences.notifyOverfilledDrives = true
        let monitor = makeMonitor(MountedVolumeInfo(name: "USB", isExternal: true, freeBytes: 500, totalBytes: 1000))

        monitor.evaluate(mountedVolume: anyURL)

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_bothTogglesOff_firesNothing() {
        preferences.notifyDriveConnected = false
        preferences.notifyOverfilledDrives = false
        let monitor = makeMonitor(MountedVolumeInfo(name: "USB", isExternal: true, freeBytes: 1, totalBytes: 1000))

        monitor.evaluate(mountedVolume: anyURL)

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }
}
