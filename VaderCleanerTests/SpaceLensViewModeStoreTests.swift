// SpaceLensViewModeStoreTests.swift
// Tests that SpaceLensViewModeStore defaults to the treemap and persists the user's pick through an injected UserDefaults.

import XCTest
@testable import VaderCleaner

@MainActor
final class SpaceLensViewModeStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Isolated suite per test so reads/writes never touch the host's real
        // .standard defaults and tests can't observe each other's state.
        suiteName = "VaderCleanerTests.SpaceLensViewMode.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A fresh install with no stored value falls back to the sunburst — the
    /// default Space Lens view.
    func test_defaultsToSunburst() {
        let sut = SpaceLensViewModeStore(defaults: defaults)
        XCTAssertEqual(sut.mode, .sunburst)
    }

    /// The chosen mode survives across store instances (i.e. an app relaunch).
    func test_persistsModeAcrossInstances() {
        let writer = SpaceLensViewModeStore(defaults: defaults)
        writer.mode = .treemap

        let reader = SpaceLensViewModeStore(defaults: defaults)
        XCTAssertEqual(reader.mode, .treemap)
    }

    /// An unrecognized persisted string (e.g. a value from a future build)
    /// falls back to the default rather than crashing.
    func test_unknownStoredValueFallsBackToDefault() {
        defaults.set("hexagons", forKey: "spaceLens.viewMode")
        let sut = SpaceLensViewModeStore(defaults: defaults)
        XCTAssertEqual(sut.mode, .sunburst)
    }
}
