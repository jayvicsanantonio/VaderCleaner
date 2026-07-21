// SmartScanSettingsStoreTests.swift
// Tests that SmartScanSettingsStore enables/disables care domains and System Junk categories, migrates the legacy module array, derives the Cleanup tri-state, and persists choices through an injected UserDefaults.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanSettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Per-test suite so persistence assertions never cross-contaminate.
        suiteName = "VaderCleanerTests.SmartScanSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func test_freshInstall_everyDomainEnabled() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.enabledDomains, Set(CareDomain.allCases))
        for domain in CareDomain.allCases {
            XCTAssertTrue(sut.isDomainEnabled(domain), "\(domain) should default to enabled")
        }
    }

    func test_defaults_allJunkCategoriesEnabled() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.enabledJunkCategories, Set(SmartScanSettingsStore.junkCategories))
    }

    // MARK: - Domain toggles & persistence

    func test_setDomain_persistsAcrossInstances() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        sut.setDomain(.myClutter, enabled: false)
        XCTAssertFalse(sut.isDomainEnabled(.myClutter))

        let reloaded = SmartScanSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.isDomainEnabled(.myClutter))
        XCTAssertTrue(reloaded.isDomainEnabled(.systemJunk))
    }

    func test_missingDictionaryEntry_meansEnabled() {
        // A future build's new domain won't be in an old install's dictionary;
        // absent must read as enabled so new features default on.
        defaults.set(["myClutter": false], forKey: "smartScan.moduleStates")
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertFalse(sut.isDomainEnabled(.myClutter))
        XCTAssertTrue(sut.isDomainEnabled(.browserPrivacy))
        XCTAssertTrue(sut.isDomainEnabled(.performance))
    }

    func test_corruptDictionaryValues_degradeToEnabled() {
        defaults.set(["malware": "banana", "unknownDomain": false], forKey: "smartScan.moduleStates")
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertTrue(sut.isDomainEnabled(.malware), "non-bool values are dropped, not treated as off")
    }

    // MARK: - Legacy module-array migration

    func test_legacyAllOnArray_migratesToEverythingEnabled() {
        defaults.set(
            ["systemJunk", "malware", "performance", "applications", "myClutter"],
            forKey: "smartScan.enabledModules"
        )
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.enabledDomains, Set(CareDomain.allCases))
    }

    func test_legacyCustomizedArray_preservesChoices_andEnablesNewDomains() {
        // A user who kept only Cleanup and Protection: those choices survive,
        // and Browser Privacy (which the legacy build didn't know) starts on.
        defaults.set(["systemJunk", "malware"], forKey: "smartScan.enabledModules")
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertTrue(sut.isDomainEnabled(.systemJunk))
        XCTAssertTrue(sut.isDomainEnabled(.malware))
        XCTAssertFalse(sut.isDomainEnabled(.performance), "a legacy exclusion stays excluded")
        XCTAssertFalse(sut.isDomainEnabled(.applications))
        XCTAssertFalse(sut.isDomainEnabled(.myClutter))
        XCTAssertTrue(sut.isDomainEnabled(.browserPrivacy), "domains the legacy build didn't know default on")
    }

    func test_legacyMigration_writesTheNewFormat_once() {
        defaults.set(["systemJunk"], forKey: "smartScan.enabledModules")
        _ = SmartScanSettingsStore(defaults: defaults)
        XCTAssertNotNil(defaults.dictionary(forKey: "smartScan.moduleStates"), "migration persists the new format")

        // The migrated dictionary is now authoritative: mutating the legacy
        // key afterwards changes nothing.
        defaults.set(["systemJunk", "malware", "performance"], forKey: "smartScan.enabledModules")
        let reloaded = SmartScanSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.isDomainEnabled(.malware))
    }

    func test_legacyUnknownRawValues_areDropped() {
        defaults.set(["systemJunk", "notARealModule"], forKey: "smartScan.enabledModules")
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertTrue(sut.isDomainEnabled(.systemJunk))
    }

    // MARK: - Junk categories (unchanged contract)

    func test_junkCategoryToggle_persists() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        sut.setJunkCategory(.userCache, enabled: false)
        XCTAssertFalse(sut.isJunkCategoryEnabled(.userCache))
        let reloaded = SmartScanSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.isJunkCategoryEnabled(.userCache))
    }

    func test_junkCategories_excludeMyClutterCategories() {
        XCTAssertFalse(SmartScanSettingsStore.junkCategories.contains(.largeFile))
        XCTAssertFalse(SmartScanSettingsStore.junkCategories.contains(.oldFile))
    }

    func test_unknownStoredJunkCategory_isDropped() {
        defaults.set(["userCache", "definitelyNotACategory"], forKey: "smartScan.enabledJunkCategories")
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.enabledJunkCategories, [.userCache])
    }

    // MARK: - Scanning tree completeness

    func test_scanningTree_exposesAToggleForEveryScannableUnit() {
        // Every domain-bound sub-scan must have a user-facing checkbox in the
        // Scanning settings tree, so a scan can never run with no way to skip it.
        // `healthSnapshot` is intentionally excluded — it has no domain, is
        // instant and non-destructive, and always rides along.
        let domainBound = Set(CareScanUnit.allCases.filter { $0.domain != nil })
        XCTAssertEqual(
            ScanningTab.toggleableUnits, domainBound,
            "Scanning tree is missing a toggle for: \(domainBound.subtracting(ScanningTab.toggleableUnits))"
        )
    }

    func test_scanningTree_exposesAToggleForEveryJunkCategory() {
        // The System Junk categories (plus the Cleanup-level leaves) must each be
        // toggleable, so no scanned-and-filtered category is silently forced on.
        XCTAssertEqual(
            ScanningTab.toggleableJunkCategories,
            Set(SmartScanSettingsStore.junkCategories)
        )
    }

    // MARK: - Scan units (per-feature granularity)

    func test_freshInstall_everyUnitEnabled() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.enabledUnits, Set(CareScanUnit.allCases))
        for unit in CareScanUnit.allCases {
            XCTAssertTrue(sut.isUnitEnabled(unit), "\(unit) should default to enabled")
        }
    }

    func test_setUnit_persistsAcrossInstances() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        sut.setUnit(.duplicates, enabled: false)
        XCTAssertFalse(sut.isUnitEnabled(.duplicates))
        XCTAssertFalse(sut.enabledUnits.contains(.duplicates))

        let reloaded = SmartScanSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.isUnitEnabled(.duplicates))
        XCTAssertTrue(reloaded.isUnitEnabled(.largeOldFiles))
    }

    func test_missingUnitEntry_meansEnabled() {
        // A future build's new unit won't be in an old install's dictionary;
        // absent must read as enabled so new sub-scans default on.
        defaults.set(["duplicates": false], forKey: "smartScan.unitStates")
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertFalse(sut.isUnitEnabled(.duplicates))
        XCTAssertTrue(sut.isUnitEnabled(.installers))
    }

    // MARK: - Restore defaults

    func test_restoreDefaults_reEnablesEveryDomainCategoryAndUnit() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        sut.setDomain(.myClutter, enabled: false)
        sut.setDomain(.performance, enabled: false)
        sut.setJunkCategory(.userCache, enabled: false)
        sut.setJunkCategory(.languageFiles, enabled: false)
        sut.setUnit(.duplicates, enabled: false)
        sut.setUnit(.loginItems, enabled: false)

        sut.restoreDefaults()

        XCTAssertEqual(sut.enabledDomains, Set(CareDomain.allCases))
        XCTAssertEqual(sut.enabledJunkCategories, Set(SmartScanSettingsStore.junkCategories))
        XCTAssertEqual(sut.enabledUnits, Set(CareScanUnit.allCases))
        XCTAssertEqual(sut.junkCategoryState, .on)
    }

    func test_restoreDefaults_persistsAcrossInstances() {
        let writer = SmartScanSettingsStore(defaults: defaults)
        writer.setDomain(.malware, enabled: false)
        writer.setJunkCategory(.userCache, enabled: false)

        writer.restoreDefaults()

        let reader = SmartScanSettingsStore(defaults: defaults)
        XCTAssertTrue(reader.isDomainEnabled(.malware))
        XCTAssertTrue(reader.isJunkCategoryEnabled(.userCache))
    }

    // MARK: - Cleanup tri-state

    func test_junkCategoryState_triState() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.junkCategoryState, .on)

        sut.setJunkCategory(.userCache, enabled: false)
        XCTAssertEqual(sut.junkCategoryState, .mixed)

        sut.setDomain(.systemJunk, enabled: false)
        XCTAssertEqual(sut.junkCategoryState, .off)
    }
}
