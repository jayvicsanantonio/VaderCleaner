// AppUpdatesMonitorSuppressionTests.swift
// Verifies the daily update notification honours declined versions, so skipping an update in the Updater also silences the background nag about it.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUpdatesMonitorSuppressionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AppUpdatesMonitorSuppressionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    /// Skipping a version in the Updater must also stop the daily
    /// notification about it. Announcing an update the user explicitly
    /// declined is exactly the nag that skip-version exists to end.
    func test_liveCount_excludesSkippedVersions() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(latest: "2.0"))

        let count = AppUpdatesMonitor.announceableCount(
            for: [update(latest: "2.0")],
            suppression: store.snapshot()
        )

        XCTAssertEqual(count, 0)
    }

    /// A later release still gets announced — skipping one version is not
    /// muting the app.
    func test_liveCount_countsANewerVersionThanTheOneSkipped() {
        let store = UpdateSuppressionStore(defaults: defaults)
        store.skip(update(latest: "2.0"))

        let count = AppUpdatesMonitor.announceableCount(
            for: [update(latest: "2.1")],
            suppression: store.snapshot()
        )

        XCTAssertEqual(count, 1)
    }

    /// Updates nobody declined are counted as before.
    func test_liveCount_countsUndeclinedUpdates() {
        let count = AppUpdatesMonitor.announceableCount(
            for: [update(latest: "2.0"), update(bundleID: "com.acme.other", latest: "3.0")],
            suppression: UpdateSuppressionSnapshot()
        )
        XCTAssertEqual(count, 2)
    }

    private func update(
        bundleID: String = "com.acme.helio",
        latest: String
    ) -> UpdateInfo {
        UpdateInfo(
            appName: "Helio",
            bundleID: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleID).app"),
            installedVersion: "1.0",
            latestVersion: latest,
            source: .sparkle,
            updateURL: URL(string: "https://example.com/helio.zip")!
        )
    }
}
