// ProtectionSettingsStoreTests.swift
// Tests that ProtectionSettingsStore exposes the spec defaults, persists changes through an injected UserDefaults, and that ScanMode raw values stay stable.

import XCTest
@testable import VaderCleaner

@MainActor
final class ProtectionSettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Each test gets an isolated UserDefaults suite so reads/writes never
        // touch the host's real .standard defaults and tests can't observe
        // each other's state.
        suiteName = "VaderCleanerTests.ProtectionSettings.\(UUID().uuidString)"
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
        let sut = ProtectionSettingsStore(defaults: defaults)

        XCTAssertTrue(sut.scanEmailAttachments)
        XCTAssertTrue(sut.scanArchives)
        XCTAssertTrue(sut.excludeDownloadedICloudFiles)
        XCTAssertEqual(sut.scanMode, .quick)
    }

    // MARK: - Persistence

    func test_persistsBoolOptionsAcrossInstances() {
        let writer = ProtectionSettingsStore(defaults: defaults)
        writer.scanEmailAttachments = false
        writer.scanArchives = false
        writer.excludeDownloadedICloudFiles = false

        let reader = ProtectionSettingsStore(defaults: defaults)
        XCTAssertFalse(reader.scanEmailAttachments)
        XCTAssertFalse(reader.scanArchives)
        XCTAssertFalse(reader.excludeDownloadedICloudFiles)
    }

    func test_persistsScanModeAcrossInstances() {
        let writer = ProtectionSettingsStore(defaults: defaults)
        writer.scanMode = .deep

        let reader = ProtectionSettingsStore(defaults: defaults)
        XCTAssertEqual(reader.scanMode, .deep)
    }

    // MARK: - ScanMode contract

    func test_scanMode_rawValuesAreStable() {
        // The raw values are persisted keys — a drift here would silently
        // reset a user's saved mode on upgrade.
        XCTAssertEqual(ScanMode.quick.rawValue, "quick")
        XCTAssertEqual(ScanMode.balanced.rawValue, "balanced")
        XCTAssertEqual(ScanMode.deep.rawValue, "deep")
        XCTAssertEqual(ScanMode.allCases, [.quick, .balanced, .deep])
    }

    func test_scanMode_unknownPersistedValueFallsBackToDefault() {
        defaults.set("nonsense", forKey: "protection.scanMode")
        let sut = ProtectionSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.scanMode, .quick)
    }
}
