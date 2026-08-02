// UpdateSuppressionStoreTests.swift
// Drives the store behind "Skip This Version" — per-app skip recording, resurfacing when a newer version ships, self-cleanup once the app catches up, persistence, and the Sendable snapshot the off-main probe path consumes.

import XCTest
@testable import VaderCleaner

@MainActor
final class UpdateSuppressionStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "UpdateSuppressionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Skipping

    /// Nothing is suppressed until the user asks for it.
    func test_suppresses_isFalseBeforeAnySkip() {
        let store = UpdateSuppressionStore(defaults: defaults)
        XCTAssertFalse(store.suppresses(update(version: "2.0")))
    }

    /// Skipping a version hides exactly that update.
    func test_suppresses_isTrueForTheSkippedVersion() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))
        XCTAssertTrue(store.suppresses(update(version: "2.0")))
    }

    /// Skips are per app — one app's choice must not silence another's.
    func test_suppresses_doesNotLeakAcrossApps() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(bundleID: "com.acme.a", version: "2.0"))
        XCTAssertFalse(store.suppresses(update(bundleID: "com.acme.b", version: "2.0")))
    }

    /// The point of *skip a version* rather than *ignore this app*: a
    /// later release resurfaces. Without this the control would silently
    /// be a permanent mute and the user would stop hearing about security
    /// fixes.
    func test_suppresses_isFalseOnceANewerVersionShips() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))
        XCTAssertFalse(store.suppresses(update(version: "2.1")))
        XCTAssertFalse(store.suppresses(update(version: "3.0")))
    }

    /// An older version than the one skipped stays suppressed — a feed
    /// briefly regressing must not resurface a declined update.
    func test_suppresses_isTrueForAnOlderVersionThanSkipped() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))
        XCTAssertTrue(store.suppresses(update(version: "1.9")))
    }

    /// Skipping again at a higher version moves the bar up.
    func test_skip_replacesTheRecordedVersion() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))
        store.skip(update(version: "2.1"))
        XCTAssertTrue(store.suppresses(update(version: "2.1")))
        XCTAssertFalse(store.suppresses(update(version: "2.2")))
    }

    // MARK: - Clearing

    /// The user can change their mind.
    func test_clearSkip_resurfacesTheUpdate() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))
        store.clearSkip(forBundleID: "com.acme.helio")
        XCTAssertFalse(store.suppresses(update(version: "2.0")))
    }

    /// Clearing an app that was never skipped is a no-op, not a crash.
    func test_clearSkip_isHarmlessWhenNothingWasSkipped() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.clearSkip(forBundleID: "com.acme.nothing")
        XCTAssertFalse(store.suppresses(update(version: "2.0")))
    }

    /// Once the installed version catches up to (or passes) the skipped
    /// one, the record describes nothing and is dropped — otherwise a
    /// reinstall at an older version would stay silently muted.
    func test_skippedVersions_dropsEntriesTheInstalledVersionHasReached() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))
        store.pruneSkips(installedVersionsByBundleID: ["com.acme.helio": "2.0"])
        XCTAssertTrue(store.skippedVersions.isEmpty)
    }

    /// Pruning leaves a still-meaningful record alone.
    func test_pruneSkips_keepsEntriesStillAheadOfInstalled() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))
        store.pruneSkips(installedVersionsByBundleID: ["com.acme.helio": "1.5"])
        XCTAssertEqual(store.skippedVersions["com.acme.helio"], "2.0")
    }

    // MARK: - Persistence

    /// Choices survive relaunch — a skip that forgot itself would nag
    /// again on next launch, which is the whole complaint.
    func test_skip_persistsAcrossStoreInstances() {
        UpdateSuppressionStore(defaults: defaults).skip(update(version: "2.0"))
        let reloaded = UpdateSuppressionStore(defaults: defaults)
        XCTAssertTrue(reloaded.suppresses(update(version: "2.0")))
    }

    /// A malformed persisted payload degrades to "nothing skipped" rather
    /// than trapping — suppressing nothing is the safe direction.
    func test_init_toleratesMalformedPersistedValue() {
        defaults.set(["com.acme.helio": 42], forKey: "updater.skippedVersions")
        let store = UpdateSuppressionStore(defaults: defaults)
        XCTAssertFalse(store.suppresses(update(version: "2.0")))
    }

    // MARK: - Snapshot

    /// The probe path runs off the main actor, so it consumes an
    /// immutable snapshot rather than reaching into the store.
    func test_snapshot_matchesStoreDecisions() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))
        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.suppresses(update(version: "2.0")))
        XCTAssertFalse(snapshot.suppresses(update(version: "2.1")))
    }

    /// A snapshot is a value taken at a moment; later skips don't
    /// retroactively change a check already in flight.
    func test_snapshot_isNotAffectedByLaterSkips() {
        let store = UpdateSuppressionStore(defaults: defaults)
        let snapshot = store.snapshot()
        store.skip(update(version: "2.0"))
        XCTAssertFalse(snapshot.suppresses(update(version: "2.0")))
    }

    /// The surfaces that only render a list (Smart Scan, the Applications
    /// dashboard) own no store, so they read the persisted decisions
    /// directly. What they see must be what the Updater wrote — otherwise
    /// a skip holds on one screen and not the next.
    func test_current_readsWhatTheUpdaterPersisted() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(version: "2.0"))

        let snapshot = UpdateSuppressionSnapshot.current(defaults: defaults)

        XCTAssertTrue(snapshot.suppresses(update(version: "2.0")))
        XCTAssertFalse(snapshot.suppresses(update(version: "2.1")))
    }

    // MARK: - Fixtures

    private func update(
        bundleID: String = "com.acme.helio",
        version: String
    ) -> UpdateInfo {
        UpdateInfo(
            appName: "Helio",
            bundleID: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/Helio.app"),
            installedVersion: "1.0",
            latestVersion: version,
            source: .sparkle,
            updateURL: URL(string: "https://example.com/helio.dmg")!
        )
    }
}
