// SettingsRestoreTests.swift
// Proves "Restore Defaults" reaches every store the Settings window writes to, including the two scan-folder scopes it used to miss.

import XCTest
@testable import VaderCleaner

/// The Restore Defaults dialog says "Your settings go back to how they started".
/// It reset three of the five stores the Settings window edits — the Web
/// Development Junk and My Clutter scan folders, both picked inside the Scanning
/// tab, survived untouched.
@MainActor
final class SettingsRestoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var home: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "VaderCleanerTests.SettingsRestore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        home = URL(fileURLWithPath: "/tmp/SettingsRestoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        home = nil
        try await super.tearDown()
    }

    /// The five stores Restore Defaults has to reach, all sharing this test's
    /// isolated suite.
    private struct Stores {
        let preferences: PreferencesStore
        let protection: ProtectionSettingsStore
        let smartScan: SmartScanSettingsStore
        let webDev: WebDevScanScopeStore
        let myClutter: MyClutterScanScopeStore

        @MainActor
        func restore() {
            SettingsRestore.restoreAll(
                preferences: preferences,
                protection: protection,
                smartScan: smartScan,
                webDevScanScope: webDev,
                myClutterScanScope: myClutter
            )
        }
    }

    private func makeStores() -> Stores {
        Stores(
            preferences: PreferencesStore(defaults: defaults),
            protection: ProtectionSettingsStore(defaults: defaults),
            smartScan: SmartScanSettingsStore(defaults: defaults),
            webDev: WebDevScanScopeStore(defaults: defaults, homeDirectory: home),
            myClutter: MyClutterScanScopeStore(defaults: defaults, homeDirectory: home)
        )
    }

    func test_restoreAll_resetsTheScanFolderScopes() {
        let stores = makeStores()
        stores.webDev.selectFolder(URL(fileURLWithPath: "/tmp/some-projects"))
        stores.myClutter.selectFolder(URL(fileURLWithPath: "/tmp/some-clutter"))

        stores.restore()

        XCTAssertTrue(stores.webDev.isDefault, "the Web Development Junk folder must go back to the default scope")
        XCTAssertTrue(stores.myClutter.isHome, "the My Clutter folder must go back to the home scope")
    }

    /// The reset has to persist, not just clear the in-memory value — otherwise
    /// the picked folder comes back on the next launch.
    func test_restoreAll_persistsTheScanFolderReset() {
        let stores = makeStores()
        stores.webDev.selectFolder(URL(fileURLWithPath: "/tmp/some-projects"))
        stores.myClutter.selectFolder(URL(fileURLWithPath: "/tmp/some-clutter"))

        stores.restore()

        XCTAssertTrue(WebDevScanScopeStore(defaults: defaults, homeDirectory: home).isDefault)
        XCTAssertTrue(MyClutterScanScopeStore(defaults: defaults, homeDirectory: home).isHome)
    }

    func test_restoreAll_stillResetsThePreferenceStores() {
        let stores = makeStores()
        stores.preferences.notifyLowDisk = !PreferencesStore.defaultNotifyLowDisk
        stores.preferences.diskFreeThresholdGB = 999
        stores.protection.scanArchives = !ProtectionSettingsStore.defaultScanArchives
        stores.protection.scanMode = .deep
        stores.smartScan.setDomain(.malware, enabled: false)
        stores.smartScan.setUnit(.duplicates, enabled: false)
        stores.smartScan.setJunkCategory(.systemCache, enabled: false)

        stores.restore()

        XCTAssertEqual(stores.preferences.notifyLowDisk, PreferencesStore.defaultNotifyLowDisk)
        XCTAssertEqual(stores.preferences.diskFreeThresholdGB, PreferencesStore.defaultDiskFreeThresholdGB)
        XCTAssertEqual(stores.protection.scanArchives, ProtectionSettingsStore.defaultScanArchives)
        XCTAssertEqual(stores.protection.scanMode, ProtectionSettingsStore.defaultScanMode)
        XCTAssertTrue(stores.smartScan.isDomainEnabled(.malware))
        XCTAssertTrue(stores.smartScan.isUnitEnabled(.duplicates))
        XCTAssertTrue(stores.smartScan.isJunkCategoryEnabled(.systemCache))
    }

    /// The dialog promises the Ignore List is left alone — those paths are user
    /// data, not a preference.
    func test_restoreAll_leavesTheIgnoreListAlone() {
        let stores = makeStores()
        let exclusions = ExclusionsStore(defaults: defaults)
        exclusions.add(path: "/tmp/keep-ignoring-me")
        let ignored = exclusions.exclusions

        stores.restore()

        XCTAssertEqual(exclusions.exclusions, ignored)
        XCTAssertEqual(ExclusionsStore(defaults: defaults).exclusions, ignored)
    }
}
