// AppUpdatesMonitorTests.swift
// Tests that the app-updates monitor only probes when the toggle allows it, notifies on new findings, and doesn't repeat the same result.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUpdatesMonitorTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Counts probe invocations so the tests can prove the expensive network
    /// work is skipped, not merely that the banner is suppressed.
    private var probeCount = 0

    override func setUp() {
        super.setUp()
        suiteName = "VaderCleanerTests.AppUpdates.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        preferences = PreferencesStore(defaults: defaults)
        dispatcher = StubNotificationDispatcher()
        probeCount = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        preferences = nil
        dispatcher = nil
        super.tearDown()
    }

    private func makeMonitor(updateCount: @escaping () -> Int) -> AppUpdatesMonitor {
        AppUpdatesMonitor(
            preferences: preferences,
            dispatcher: dispatcher,
            probe: { [weak self] in
                self?.probeCount += 1
                return updateCount()
            },
            defaults: defaults,
            now: { self.now }
        )
    }

    // MARK: - Probe budget

    /// `start()` runs a check immediately, so without a persisted timestamp
    /// every launch would probe the network once per installed app. Launching
    /// twice in a day must only probe once.
    func test_skipsTheProbeWhenOneRanRecently_evenAcrossInstances() async {
        await makeMonitor(updateCount: { 2 }).check()
        XCTAssertEqual(probeCount, 1)

        now = now.addingTimeInterval(60 * 60)
        await makeMonitor(updateCount: { 2 }).check()

        XCTAssertEqual(probeCount, 1, "a fresh instance must respect the persisted last-check time")
    }

    func test_probesAgainOnceTheIntervalHasElapsed() async {
        await makeMonitor(updateCount: { 2 }).check()
        now = now.addingTimeInterval(25 * 60 * 60)

        await makeMonitor(updateCount: { 2 }).check()

        XCTAssertEqual(probeCount, 2)
    }

    /// A skipped probe must not also swallow the notification decision — the
    /// count memo lives with the probe, so a suppressed run simply does nothing.
    func test_skippedProbe_sendsNothing() async {
        await makeMonitor(updateCount: { 2 }).check()
        dispatcher = StubNotificationDispatcher()

        now = now.addingTimeInterval(60)
        await makeMonitor(updateCount: { 9 }).check()

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_notifiesWhenUpdatesAreAvailable() async {
        let monitor = makeMonitor(updateCount: { 4 })

        await monitor.check()

        XCTAssertEqual(dispatcher.calls, [.appUpdates(count: 4)])
    }

    func test_staysSilentWhenEverythingIsUpToDate() async {
        let monitor = makeMonitor(updateCount: { 0 })

        await monitor.check()

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    /// The toggle has to gate the probe itself, not just the banner — this is
    /// a network call per installed app, and an "off" switch that still probes
    /// would be a lie about battery and bandwidth.
    func test_toggleOff_skipsTheProbeEntirely() async {
        preferences.notifyAppUpdates = false
        let monitor = makeMonitor(updateCount: { 4 })

        await monitor.check()

        XCTAssertEqual(probeCount, 0, "no network work may happen while the toggle is off")
        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    /// Re-announcing the same pending updates every day is nagging. Only a
    /// change in what's available is worth another banner.
    func test_doesNotRepeatTheSameCount() async {
        let monitor = makeMonitor(updateCount: { 4 })

        await monitor.check()
        now = now.addingTimeInterval(24 * 60 * 60)
        await monitor.check()

        XCTAssertEqual(dispatcher.calls.count, 1)
    }

    /// The "already told you about these" memo has to survive a relaunch too,
    /// or quitting and reopening the app re-announces the same updates.
    func test_doesNotRepeatTheSameCountAcrossInstances() async {
        await makeMonitor(updateCount: { 4 }).check()
        now = now.addingTimeInterval(24 * 60 * 60)

        await makeMonitor(updateCount: { 4 }).check()

        XCTAssertEqual(dispatcher.calls.count, 1)
    }

    func test_notifiesAgainWhenMoreUpdatesAppear() async {
        var count = 4
        let monitor = makeMonitor(updateCount: { count })

        await monitor.check()
        count = 6
        now = now.addingTimeInterval(24 * 60 * 60)
        await monitor.check()

        XCTAssertEqual(dispatcher.calls, [.appUpdates(count: 4), .appUpdates(count: 6)])
    }

    /// Dropping to zero (the user updated everything) then finding new ones
    /// later must announce again rather than staying suppressed.
    func test_notifiesAgainAfterEverythingWasUpdated() async {
        var count = 3
        let monitor = makeMonitor(updateCount: { count })

        await monitor.check()
        count = 0
        now = now.addingTimeInterval(24 * 60 * 60)
        await monitor.check()
        count = 3
        now = now.addingTimeInterval(24 * 60 * 60)
        await monitor.check()

        XCTAssertEqual(dispatcher.calls, [.appUpdates(count: 3), .appUpdates(count: 3)])
    }
}
