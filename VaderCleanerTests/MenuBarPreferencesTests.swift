// MenuBarPreferencesTests.swift
// Tests the menu bar preferences: the reading picker and its migration from the old boolean, Dock retention, panel row visibility, and the stats update cadence.

import XCTest
@testable import VaderCleaner

@MainActor
final class MenuBarPreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VaderCleanerTests.MenuBarPrefs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Reading

    /// Nothing beside the icon by default: a wide label is prone to hiding
    /// behind the notch, so showing a number stays opt-in.
    func test_reading_defaultsToNothing() {
        XCTAssertEqual(PreferencesStore(defaults: defaults).menuBarReading, .none)
    }

    func test_reading_persistsAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.menuBarReading = .cpu

        XCTAssertEqual(PreferencesStore(defaults: defaults).menuBarReading, .cpu)
    }

    /// Someone who opted into the old free-space readout must keep seeing it
    /// after the upgrade — the boolean becomes the free-space case.
    func test_reading_migratesFromTheLegacyBoolean() {
        defaults.set(true, forKey: "preferences.menuBarShowsReading")

        XCTAssertEqual(PreferencesStore(defaults: defaults).menuBarReading, .freeSpace)
    }

    func test_reading_migratesLegacyFalseToNothing() {
        defaults.set(false, forKey: "preferences.menuBarShowsReading")

        XCTAssertEqual(PreferencesStore(defaults: defaults).menuBarReading, .none)
    }

    /// An explicit new-format choice must win over the legacy key, or changing
    /// the picker would be undone on every launch.
    func test_reading_prefersTheExplicitChoiceOverTheLegacyBoolean() {
        defaults.set(true, forKey: "preferences.menuBarShowsReading")
        defaults.set(MenuBarReading.memory.rawValue, forKey: "preferences.menuBarReading")

        XCTAssertEqual(PreferencesStore(defaults: defaults).menuBarReading, .memory)
    }

    /// Raw values are the persisted representation and must stay stable.
    func test_readingRawValues_areStable() {
        XCTAssertEqual(MenuBarReading.none.rawValue, "none")
        XCTAssertEqual(MenuBarReading.freeSpace.rawValue, "freeSpace")
        XCTAssertEqual(MenuBarReading.memory.rawValue, "memory")
        XCTAssertEqual(MenuBarReading.cpu.rawValue, "cpu")
    }

    // MARK: - Dock

    func test_keepDockIcon_defaultsOff() {
        XCTAssertFalse(PreferencesStore(defaults: defaults).keepDockIcon)
    }

    /// The invariant behind the presence picker: the user must never be able to
    /// hide the menu bar icon *and* the Dock icon, leaving no way back in.
    func test_presence_cannotReachNeither() {
        let sut = PreferencesStore(defaults: defaults)

        sut.menuBarPresence = .dockOnly
        XCTAssertFalse(sut.showMenuBar)
        XCTAssertTrue(sut.keepDockIcon)

        sut.menuBarPresence = .menuBarOnly
        XCTAssertTrue(sut.showMenuBar)
        XCTAssertFalse(sut.keepDockIcon)

        sut.menuBarPresence = .both
        XCTAssertTrue(sut.showMenuBar)
        XCTAssertTrue(sut.keepDockIcon)
    }

    func test_presence_readsBackFromTheUnderlyingFlags() {
        let sut = PreferencesStore(defaults: defaults)

        sut.showMenuBar = true
        sut.keepDockIcon = false
        XCTAssertEqual(sut.menuBarPresence, .menuBarOnly)

        sut.keepDockIcon = true
        XCTAssertEqual(sut.menuBarPresence, .both)

        sut.showMenuBar = false
        XCTAssertEqual(sut.menuBarPresence, .dockOnly)
    }

    /// Defensive: if both flags are somehow off (a hand-edited defaults file),
    /// report Dock-only rather than a state the picker can't render.
    func test_presence_degradesToDockOnlyWhenBothFlagsAreOff() {
        let sut = PreferencesStore(defaults: defaults)
        sut.showMenuBar = false
        sut.keepDockIcon = false

        XCTAssertEqual(sut.menuBarPresence, .dockOnly)
    }

    // MARK: - Panel rows

    /// Missing means enabled, so a new row added in a later release shows up
    /// for existing users instead of being invisibly off.
    func test_panelRows_defaultToEnabled() {
        let sut = PreferencesStore(defaults: defaults)

        for row in MenuBarPanelRow.allCases {
            XCTAssertTrue(sut.isPanelRowEnabled(row), "\(row) should default to visible")
        }
    }

    func test_panelRows_persistAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.setPanelRow(.network, enabled: false)
        writer.setPanelRow(.devices, enabled: false)

        let reader = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reader.isPanelRowEnabled(.network))
        XCTAssertFalse(reader.isPanelRowEnabled(.devices))
        XCTAssertTrue(reader.isPanelRowEnabled(.storage))
    }

    func test_panelRowRawValues_areStable() {
        XCTAssertEqual(
            Set(MenuBarPanelRow.allCases.map(\.rawValue)),
            ["protection", "storage", "memory", "cpu", "network", "devices"]
        )
    }

    // MARK: - Stats cadence

    func test_statsInterval_defaultsToTwoSeconds() {
        XCTAssertEqual(PreferencesStore(defaults: defaults).statsUpdateInterval, 2)
    }

    func test_statsInterval_persistsAcrossInstances() {
        let writer = PreferencesStore(defaults: defaults)
        writer.statsUpdateInterval = 10

        XCTAssertEqual(PreferencesStore(defaults: defaults).statsUpdateInterval, 10)
    }

    // MARK: - Restore defaults

    func test_restoreDefaults_resetsTheMenuBarSettings() {
        let sut = PreferencesStore(defaults: defaults)
        sut.menuBarReading = .cpu
        sut.keepDockIcon = true
        sut.statsUpdateInterval = 10
        sut.setPanelRow(.network, enabled: false)

        sut.restoreDefaults()

        XCTAssertEqual(sut.menuBarReading, PreferencesStore.defaultMenuBarReading)
        XCTAssertEqual(sut.keepDockIcon, PreferencesStore.defaultKeepDockIcon)
        XCTAssertEqual(sut.statsUpdateInterval, PreferencesStore.defaultStatsUpdateInterval)
        XCTAssertTrue(sut.isPanelRowEnabled(.network), "hidden rows come back on a reset")
    }
}
