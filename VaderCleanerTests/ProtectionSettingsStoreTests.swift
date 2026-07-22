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
        // Quick by default — the high-risk home subdirectories only, matching
        // Smart Scan's threat scope, so a first scan is fast rather than a
        // whole-$HOME Deep pass.
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

    // MARK: - Restore defaults

    func test_restoreDefaults_resetsEveryOptionToSpec() {
        let sut = ProtectionSettingsStore(defaults: defaults)
        sut.scanEmailAttachments = false
        sut.scanArchives = false
        sut.excludeDownloadedICloudFiles = false
        sut.scanMode = .deep

        sut.restoreDefaults()

        XCTAssertEqual(sut.scanEmailAttachments, ProtectionSettingsStore.defaultScanEmailAttachments)
        XCTAssertEqual(sut.scanArchives, ProtectionSettingsStore.defaultScanArchives)
        XCTAssertEqual(sut.excludeDownloadedICloudFiles, ProtectionSettingsStore.defaultExcludeDownloadedICloudFiles)
        XCTAssertEqual(sut.scanMode, ProtectionSettingsStore.defaultScanMode)
    }

    func test_restoreDefaults_persistsAcrossInstances() {
        let writer = ProtectionSettingsStore(defaults: defaults)
        writer.scanArchives = false
        writer.scanMode = .deep

        writer.restoreDefaults()

        let reader = ProtectionSettingsStore(defaults: defaults)
        XCTAssertEqual(reader.scanArchives, ProtectionSettingsStore.defaultScanArchives)
        XCTAssertEqual(reader.scanMode, ProtectionSettingsStore.defaultScanMode)
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

    func test_scanMode_quickPurposeDescribesPersistenceVectorsNotUserFolders() {
        // Quick checks startup items and browser extensions, not the user
        // folders (see `MalwareViewModel.scanScope`). Copy still promising
        // Downloads or Desktop would describe a scan we no longer run, and
        // would send someone worried about a fresh download to the wrong mode.
        for folder in ["Downloads", "Desktop", "Documents"] {
            XCTAssertFalse(
                ScanMode.quick.purpose.contains(folder),
                "Quick Scan copy must not promise \(folder) — Balanced and Deep cover it"
            )
        }
        XCTAssertTrue(
            ScanMode.quick.purpose.contains("startup items"),
            "Quick Scan copy should name what it actually checks"
        )
    }

    func test_scanMode_deepPurposeDescribesHomeFolderScope() {
        // Every mode is rooted at $HOME (see `MalwareViewModel.scanScope`) —
        // none of them walk /Applications, /Library or /System. The Deep card
        // is the one that could overpromise, so pin its scope claim. This
        // guards a correctness claim about coverage, not the prose style.
        XCTAssertTrue(
            ScanMode.deep.purpose.contains("home folder"),
            "Deep Scan copy should name the home folder as its scope"
        )
        XCTAssertFalse(
            ScanMode.deep.purpose.contains("on your Mac"),
            "Deep Scan copy must not promise whole-Mac coverage it doesn't deliver"
        )
    }

    func test_scanMode_unknownPersistedValueFallsBackToDefault() {
        defaults.set("nonsense", forKey: "protection.scanMode")
        let sut = ProtectionSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.scanMode, .quick)
    }
}
