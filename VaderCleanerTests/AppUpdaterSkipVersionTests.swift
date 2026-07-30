// AppUpdaterSkipVersionTests.swift
// Drives skip-this-version through the view model — declined updates withheld from the list, a later release resurfacing, coverage still counting them as checked, and stale skips pruned once the app catches up.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUpdaterSkipVersionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AppUpdaterSkipVersionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    /// A declined version stops appearing in the list.
    func test_checkForUpdates_withholdsASkippedVersion() async {
        let store = UpdateSuppressionStore(defaults: defaults)
        let vm = makeViewModel(latestVersion: "2.0", suppression: store)

        await vm.checkForUpdates()
        XCTAssertEqual(vm.availableUpdates.count, 1)

        vm.skip(vm.availableUpdates[0])
        XCTAssertTrue(vm.availableUpdates.isEmpty, "Skipping must take effect immediately")

        await vm.checkForUpdates()
        XCTAssertTrue(vm.availableUpdates.isEmpty, "And survive a re-check")
    }

    /// The distinction that makes this "skip a version" and not "mute
    /// this app": the next release comes back.
    func test_checkForUpdates_resurfacesWhenANewerVersionShips() async {
        let store = UpdateSuppressionStore(defaults: defaults)
        let vm = makeViewModel(latestVersion: "2.0", suppression: store)
        await vm.checkForUpdates()
        vm.skip(vm.availableUpdates[0])

        let next = makeViewModel(latestVersion: "2.1", suppression: store)
        await next.checkForUpdates()

        XCTAssertEqual(next.availableUpdates.map(\.latestVersion), ["2.1"])
    }

    /// A skipped app was still contacted, so it counts as checked. Moving
    /// it out of `checked` would make the coverage headline understate
    /// what the check actually did.
    func test_checkForUpdates_skippedUpdateStillCountsAsChecked() async {
        let store = UpdateSuppressionStore(defaults: defaults)
        let vm = makeViewModel(latestVersion: "2.0", suppression: store)
        await vm.checkForUpdates()
        vm.skip(vm.availableUpdates[0])

        await vm.checkForUpdates()

        XCTAssertEqual(vm.coverage.checked, 1)
        XCTAssertEqual(vm.coverage.total, 1)
        XCTAssertTrue(vm.coverage.unmonitored.isEmpty)
    }

    /// A skipped update stays listed under its own facet. A choice the
    /// user cannot find again is indistinguishable from the update having
    /// vanished, which is how "skip" turns into a support question.
    func test_skip_movesTheUpdateIntoSkippedUpdates() async {
        let store = UpdateSuppressionStore(defaults: defaults)
        let vm = makeViewModel(latestVersion: "2.0", suppression: store)
        await vm.checkForUpdates()

        vm.skip(vm.availableUpdates[0])

        XCTAssertEqual(vm.skippedUpdates.map(\.bundleID), ["com.acme.helio"])
        XCTAssertTrue(vm.availableUpdates.isEmpty)
    }

    /// The skipped list is rebuilt by a re-check, not just by the action.
    func test_checkForUpdates_repopulatesSkippedUpdates() async {
        let store = UpdateSuppressionStore(defaults: defaults)
        let vm = makeViewModel(latestVersion: "2.0", suppression: store)
        await vm.checkForUpdates()
        vm.skip(vm.availableUpdates[0])

        let next = makeViewModel(latestVersion: "2.0", suppression: store)
        await next.checkForUpdates()

        XCTAssertEqual(next.skippedUpdates.map(\.latestVersion), ["2.0"])
        XCTAssertTrue(next.availableUpdates.isEmpty)
    }

    /// Undoing restores the row immediately rather than making the user
    /// re-run a whole check to see the effect.
    func test_clearSkip_restoresTheRowWithoutARecheck() async {
        let store = UpdateSuppressionStore(defaults: defaults)
        let vm = makeViewModel(latestVersion: "2.0", suppression: store)
        await vm.checkForUpdates()
        vm.skip(vm.availableUpdates[0])

        vm.clearSkip(forBundleID: "com.acme.helio")

        XCTAssertEqual(vm.availableUpdates.map(\.bundleID), ["com.acme.helio"])
        XCTAssertTrue(vm.skippedUpdates.isEmpty)
    }

    /// Undoing a skip brings the update back.
    func test_clearSkip_resurfacesTheUpdate() async {
        let store = UpdateSuppressionStore(defaults: defaults)
        let vm = makeViewModel(latestVersion: "2.0", suppression: store)
        await vm.checkForUpdates()
        vm.skip(vm.availableUpdates[0])

        vm.clearSkip(forBundleID: "com.acme.helio")
        await vm.checkForUpdates()

        XCTAssertEqual(vm.availableUpdates.map(\.latestVersion), ["2.0"])
    }

    /// Once the user updates the app by other means, the record describes
    /// nothing and is dropped, so a later reinstall at an older version
    /// isn't silently muted.
    func test_checkForUpdates_prunesSkipsTheInstalledVersionHasReached() async {
        let store = UpdateSuppressionStore(defaults: defaults)
        let vm = makeViewModel(latestVersion: "2.0", suppression: store)
        await vm.checkForUpdates()
        vm.skip(vm.availableUpdates[0])
        XCTAssertEqual(store.skippedVersions["com.acme.helio"], "2.0")

        // The app is now installed at the version that was declined.
        let caughtUp = makeViewModel(
            installedVersion: "2.0",
            latestVersion: "2.0",
            suppression: store
        )
        await caughtUp.checkForUpdates()

        XCTAssertTrue(store.skippedVersions.isEmpty)
    }

    /// Without a store configured nothing is suppressed — the default
    /// keeps every other test path hermetic.
    func test_checkForUpdates_withoutSuppressionStoreOffersEverything() async {
        let vm = makeViewModel(latestVersion: "2.0", suppression: nil)
        await vm.checkForUpdates()
        XCTAssertEqual(vm.availableUpdates.count, 1)
        vm.skip(vm.availableUpdates[0])
        XCTAssertEqual(vm.availableUpdates.count, 1, "skip() is inert without a store")
    }

    // MARK: - Fixtures

    private func makeViewModel(
        installedVersion: String = "1.0",
        latestVersion: String,
        suppression: UpdateSuppressionStore?
    ) -> AppUpdaterViewModel {
        let app = AppInfo(
            name: "Helio",
            bundleID: "com.acme.helio",
            version: installedVersion,
            bundleURL: URL(fileURLWithPath: "/Applications/Helio.app"),
            isAppStore: false
        )
        return AppUpdaterViewModel(
            discover: { _ in [app] },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in
                .found(SparkleAppcastItem(
                    shortVersion: latestVersion,
                    version: nil,
                    downloadURL: URL(string: "https://example.com/helio.dmg")!
                ))
            },
            classifyUnchecked: { _ in .unmonitored },
            suppression: suppression,
            opener: { _ in }
        )
    }
}
