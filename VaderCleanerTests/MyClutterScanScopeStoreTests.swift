// MyClutterScanScopeStoreTests.swift
// Pins the My Clutter scan-scope store: default home scope, custom-folder selection, persistence, and the home-collapse edge case.

import XCTest
@testable import VaderCleaner

@MainActor
final class MyClutterScanScopeStoreTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester")

    private func makeDefaults() -> UserDefaults {
        let suite = "MyClutterScanScopeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func test_defaultScopeIsHome() {
        let store = MyClutterScanScopeStore(defaults: makeDefaults(), homeDirectory: home)

        XCTAssertTrue(store.isHome)
        XCTAssertNil(store.scanRoots, "Home scope must walk the canonical subtrees, signalled by nil roots")
        XCTAssertEqual(store.selectedURL, home)
        XCTAssertEqual(store.displayName, "tester")
    }

    func test_selectFolderScansThatFolderDirectly() {
        let store = MyClutterScanScopeStore(defaults: makeDefaults(), homeDirectory: home)
        let folder = URL(fileURLWithPath: "/Volumes/Media/Archive")

        store.selectFolder(folder)

        XCTAssertFalse(store.isHome)
        XCTAssertEqual(store.scanRoots, [folder])
        XCTAssertEqual(store.selectedURL, folder)
        XCTAssertEqual(store.displayName, "Archive")
    }

    func test_selectingHomeFolderCollapsesToHomeScope() {
        let store = MyClutterScanScopeStore(defaults: makeDefaults(), homeDirectory: home)

        store.selectFolder(home)

        XCTAssertTrue(store.isHome, "Picking the home directory explicitly must collapse to the home scope")
        XCTAssertNil(store.scanRoots)
    }

    func test_selectionPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let folder = URL(fileURLWithPath: "/Volumes/Media/Archive")

        let first = MyClutterScanScopeStore(defaults: defaults, homeDirectory: home)
        first.selectFolder(folder)

        let second = MyClutterScanScopeStore(defaults: defaults, homeDirectory: home)
        XCTAssertEqual(second.scanRoots, [folder], "A picked folder must survive a relaunch")
        XCTAssertFalse(second.isHome)
    }

    func test_selectHomeClearsAPersistedFolder() {
        let defaults = makeDefaults()
        let folder = URL(fileURLWithPath: "/Volumes/Media/Archive")

        let first = MyClutterScanScopeStore(defaults: defaults, homeDirectory: home)
        first.selectFolder(folder)
        first.selectHome()

        let second = MyClutterScanScopeStore(defaults: defaults, homeDirectory: home)
        XCTAssertTrue(second.isHome, "Returning to home must clear the persisted folder")
        XCTAssertNil(second.scanRoots)
    }
}
