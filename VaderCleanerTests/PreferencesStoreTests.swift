// PreferencesStoreTests.swift
// Tests that PreferencesStore exposes spec defaults and persists changes through an injected UserDefaults.

import XCTest
@testable import VaderCleaner

@MainActor
final class PreferencesStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Each test gets its own UserDefaults suite so reads/writes never
        // touch the host machine's real .standard defaults and tests cannot
        // observe each other's state.
        suiteName = "VaderCleanerTests.PreferencesStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func test_defaults_matchSpec() {
        let sut = PreferencesStore(defaults: defaults)

        XCTAssertTrue(sut.notifyLowDisk)
        XCTAssertTrue(sut.notifyHighRAM)
        XCTAssertTrue(sut.notifyMalwareFound)
        XCTAssertTrue(sut.notifyLargeFilesFound)
        XCTAssertEqual(sut.diskSpaceThresholdPercent, 10.0, accuracy: 0.001)
        XCTAssertTrue(sut.launchAtLogin)
        XCTAssertTrue(sut.showMenuBar)
    }

    // MARK: - Persistence

    func test_persistsBoolValueAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.notifyLowDisk = false

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.notifyLowDisk)
    }

    func test_persistsThresholdAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.diskSpaceThresholdPercent = 25.0

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reader.diskSpaceThresholdPercent, 25.0, accuracy: 0.001)
    }

    func test_persistsAllNotificationToggles() {
        let writer = PreferencesStore(defaults: defaults)
        writer.notifyLowDisk = false
        writer.notifyHighRAM = false
        writer.notifyMalwareFound = false
        writer.notifyLargeFilesFound = false

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.notifyLowDisk)
        XCTAssertFalse(reader.notifyHighRAM)
        XCTAssertFalse(reader.notifyMalwareFound)
        XCTAssertFalse(reader.notifyLargeFilesFound)
    }

    func test_persistsLaunchAndMenuBarToggles() {
        let writer = PreferencesStore(defaults: defaults)
        writer.launchAtLogin = false
        writer.showMenuBar = false

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.launchAtLogin)
        XCTAssertFalse(reader.showMenuBar)
    }
}
