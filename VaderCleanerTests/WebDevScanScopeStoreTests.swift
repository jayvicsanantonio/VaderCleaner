// WebDevScanScopeStoreTests.swift
// Pins the Web Development Junk project-scan scope store: default scope resolves to the existing common code directories under home, custom-folder selection, persistence, and reset.

import XCTest
import Observation
@testable import VaderCleaner

@MainActor
final class WebDevScanScopeStoreTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = try TestHelpers.createTempDirectory()
    }

    override func tearDown() {
        if let tempHome { TestHelpers.tearDownTempDirectory(tempHome) }
        tempHome = nil
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "WebDevScanScopeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeHomeDir(_ name: String) throws -> URL {
        let url = tempHome.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Cross-screen sync

    /// The Settings picker reads this store, and so does the visibility rule
    /// that hides the whole Web Development Junk row. Both depend on the
    /// backing property staying Observation-tracked.
    func test_selectingAFolder_notifiesObservers() throws {
        let picked = try makeHomeDir("Elsewhere")
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)
        var notified = false
        withObservationTracking {
            _ = store.selectedFolderURL
        } onChange: {
            notified = true
        }

        store.selectFolder(picked)

        XCTAssertTrue(notified)
    }

    /// Picking a folder flips the row from hidden to visible, so `isDormant`
    /// has to invalidate as well — otherwise the row a user just configured
    /// wouldn't appear until Settings was reopened.
    func test_selectingAFolder_notifiesObserversOfDormancy() throws {
        let picked = try makeHomeDir("Elsewhere")
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)
        var notified = false
        withObservationTracking {
            _ = store.isDormant
        } onChange: {
            notified = true
        }

        store.selectFolder(picked)

        XCTAssertTrue(notified)
    }

    // MARK: - Dormancy

    /// With no code folders on the Mac and no folder picked, this scan has
    /// nothing to look at — Settings hides it rather than asking a
    /// non-programmer where their "project junk" lives.
    func test_isDormant_whenNoCommonCodeDirectoriesExist() {
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)

        XCTAssertTrue(store.isDormant)
    }

    func test_isNotDormant_onceACodeDirectoryExists() throws {
        _ = try makeHomeDir("Developer")

        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)

        XCTAssertFalse(store.isDormant)
    }

    /// An explicit pick always counts, even if the folder is later removed —
    /// the user has told us they care about this scan, so it stays visible and
    /// re-configurable rather than disappearing on them.
    func test_isNotDormant_whenAFolderWasPicked() throws {
        let picked = try makeHomeDir("Elsewhere")
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)

        store.selectFolder(picked)

        XCTAssertFalse(store.isDormant)
    }

    func test_isDormantAgain_afterReturningToTheDefaultScope() throws {
        let picked = try makeHomeDir("Elsewhere")
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)
        store.selectFolder(picked)

        store.selectDefault()

        XCTAssertTrue(store.isDormant, "no common code directories exist under this home")
    }

    func test_defaultScope_walksOnlyExistingCommonCodeDirectories() throws {
        let developer = try makeHomeDir("Developer")
        let projects = try makeHomeDir("Projects")
        // "Code" intentionally not created — an absent candidate must not appear.

        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)

        XCTAssertTrue(store.isDefault)
        XCTAssertEqual(Set(store.scanRoots), [developer, projects])
        XCTAssertFalse(store.scanRoots.contains(tempHome.appendingPathComponent("Code", isDirectory: true)))
    }

    func test_defaultScope_isEmptyWhenNoCommonCodeDirectoriesExist() {
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)
        XCTAssertTrue(store.scanRoots.isEmpty, "No code directories means nothing to walk")
    }

    func test_selectFolder_scansThatFolderDirectly() {
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)
        let folder = URL(fileURLWithPath: "/Volumes/Work/monorepo")

        store.selectFolder(folder)

        XCTAssertFalse(store.isDefault)
        XCTAssertEqual(store.scanRoots, [folder])
        XCTAssertEqual(store.selectedFolderURL, folder)
    }

    func test_selectedFolderURL_isNilForDefaultScope() {
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)
        XCTAssertNil(store.selectedFolderURL)
    }

    func test_selectDefault_restoresTheDefaultScope() throws {
        let developer = try makeHomeDir("Developer")
        let store = WebDevScanScopeStore(defaults: makeDefaults(), homeDirectory: tempHome)
        store.selectFolder(URL(fileURLWithPath: "/Volumes/Work/monorepo"))

        store.selectDefault()

        XCTAssertTrue(store.isDefault)
        XCTAssertEqual(store.scanRoots, [developer])
    }

    func test_selectionPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let folder = URL(fileURLWithPath: "/Volumes/Work/monorepo")

        let first = WebDevScanScopeStore(defaults: defaults, homeDirectory: tempHome)
        first.selectFolder(folder)

        let second = WebDevScanScopeStore(defaults: defaults, homeDirectory: tempHome)
        XCTAssertFalse(second.isDefault)
        XCTAssertEqual(second.scanRoots, [folder], "A picked folder must survive a relaunch")
    }
}
