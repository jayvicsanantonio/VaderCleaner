// SmartScanSettingsStoreTests.swift
// Tests that SmartScanSettingsStore enables/disables Smart Scan modules and System Junk categories, derives the Cleanup tri-state, and persists choices through an injected UserDefaults.

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

    func test_defaults_allModulesEnabled() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.enabledModules, Set(SmartScanModule.allCases))
        for module in SmartScanModule.allCases {
            XCTAssertTrue(sut.isModuleEnabled(module), "\(module) should default to enabled")
        }
    }

    func test_defaults_allJunkCategoriesEnabled() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.enabledJunkCategories, Set(SmartScanSettingsStore.junkCategories))
        for category in SmartScanSettingsStore.junkCategories {
            XCTAssertTrue(sut.isJunkCategoryEnabled(category), "\(category) should default to enabled")
        }
    }

    // MARK: - junkCategories membership

    func test_junkCategories_excludeClutterCategories() {
        // largeFile / oldFile belong to the My Clutter module, not System Junk,
        // so they must never appear in the Cleanup sub-tree.
        XCTAssertFalse(SmartScanSettingsStore.junkCategories.contains(.largeFile))
        XCTAssertFalse(SmartScanSettingsStore.junkCategories.contains(.oldFile))
    }

    func test_junkCategories_coverEverySystemJunkCategory() {
        let expected = Set(ScanCategory.allCases).subtracting([.largeFile, .oldFile])
        XCTAssertEqual(Set(SmartScanSettingsStore.junkCategories), expected)
    }

    // MARK: - Toggling modules

    func test_setModule_disablesAndEnables() {
        let sut = SmartScanSettingsStore(defaults: defaults)

        sut.setModule(.malware, enabled: false)
        XCTAssertFalse(sut.isModuleEnabled(.malware))
        XCTAssertFalse(sut.enabledModules.contains(.malware))

        sut.setModule(.malware, enabled: true)
        XCTAssertTrue(sut.isModuleEnabled(.malware))
    }

    func test_setModule_isIndependentOfJunkCategories() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        sut.setJunkCategory(.trash, enabled: false)

        // Disabling a different module must not touch the category flags.
        sut.setModule(.applications, enabled: false)
        XCTAssertFalse(sut.isJunkCategoryEnabled(.trash))
        XCTAssertTrue(sut.isJunkCategoryEnabled(.userCache))
    }

    // MARK: - Toggling junk categories

    func test_setJunkCategory_disablesAndEnables() {
        let sut = SmartScanSettingsStore(defaults: defaults)

        sut.setJunkCategory(.trash, enabled: false)
        XCTAssertFalse(sut.isJunkCategoryEnabled(.trash))
        XCTAssertFalse(sut.enabledJunkCategories.contains(.trash))

        sut.setJunkCategory(.trash, enabled: true)
        XCTAssertTrue(sut.isJunkCategoryEnabled(.trash))
    }

    // MARK: - Cleanup tri-state

    func test_junkCategoryState_isOn_whenModuleAndAllCategoriesEnabled() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        XCTAssertEqual(sut.junkCategoryState, .on)
    }

    func test_junkCategoryState_isOff_whenModuleDisabled() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        sut.setModule(.systemJunk, enabled: false)
        XCTAssertEqual(sut.junkCategoryState, .off)
    }

    func test_junkCategoryState_isMixed_whenModuleOnButSomeCategoriesOff() {
        let sut = SmartScanSettingsStore(defaults: defaults)
        sut.setJunkCategory(.trash, enabled: false)
        XCTAssertEqual(sut.junkCategoryState, .mixed)
    }

    func test_junkCategoryState_isOff_evenIfCategoriesEnabled_whenModuleOff() {
        // Module off wins over category flags: the whole subtree is excluded.
        let sut = SmartScanSettingsStore(defaults: defaults)
        sut.setModule(.systemJunk, enabled: false)
        XCTAssertTrue(sut.isJunkCategoryEnabled(.userCache))
        XCTAssertEqual(sut.junkCategoryState, .off)
    }

    // MARK: - Persistence

    func test_persistsModuleChoiceAcrossInstances() {
        let writer = SmartScanSettingsStore(defaults: defaults)
        writer.setModule(.applications, enabled: false)
        writer.setModule(.myClutter, enabled: false)

        let reader = SmartScanSettingsStore(defaults: defaults)
        XCTAssertFalse(reader.isModuleEnabled(.applications))
        XCTAssertFalse(reader.isModuleEnabled(.myClutter))
        XCTAssertTrue(reader.isModuleEnabled(.systemJunk))
    }

    func test_persistsJunkCategoryChoiceAcrossInstances() {
        let writer = SmartScanSettingsStore(defaults: defaults)
        writer.setJunkCategory(.trash, enabled: false)
        writer.setJunkCategory(.systemLogs, enabled: false)

        let reader = SmartScanSettingsStore(defaults: defaults)
        XCTAssertFalse(reader.isJunkCategoryEnabled(.trash))
        XCTAssertFalse(reader.isJunkCategoryEnabled(.systemLogs))
        XCTAssertTrue(reader.isJunkCategoryEnabled(.userCache))
    }
}
