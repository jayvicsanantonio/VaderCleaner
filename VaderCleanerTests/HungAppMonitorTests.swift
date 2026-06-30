// HungAppMonitorTests.swift
// Verifies hung-app dispatch against the responsiveness probe, toggle, and per-process cooldown.

import XCTest
@testable import VaderCleaner

@MainActor
final class HungAppMonitorTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!
    private var virtualNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var apps: [RunningAppInfo] = []
    private var unresponsivePIDs: Set<pid_t> = []

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.HungApp.\(UUID().uuidString)")!
        preferences = PreferencesStore(defaults: defaults)
        dispatcher = StubNotificationDispatcher()
        apps = []
        unresponsivePIDs = []
    }

    private func makeMonitor() -> HungAppMonitor {
        HungAppMonitor(
            preferences: preferences,
            dispatcher: dispatcher,
            appLister: { [unowned self] in self.apps },
            isResponsive: { [unowned self] pid in !self.unresponsivePIDs.contains(pid) },
            cooldown: 60 * 60,
            now: { [unowned self] in self.virtualNow }
        )
    }

    func test_fires_forUnresponsiveAppWhenOn() {
        preferences.notifyHungApps = true
        apps = [RunningAppInfo(name: "Safari", pid: 42)]
        unresponsivePIDs = [42]
        let monitor = makeMonitor()

        monitor.evaluate()

        XCTAssertEqual(dispatcher.calls, [.hungApp(appName: "Safari")])
    }

    func test_doesNotFire_forResponsiveApp() {
        preferences.notifyHungApps = true
        apps = [RunningAppInfo(name: "Mail", pid: 7)]
        let monitor = makeMonitor()

        monitor.evaluate()

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_doesNotFire_whenToggleOff() {
        preferences.notifyHungApps = false
        apps = [RunningAppInfo(name: "Xcode", pid: 9)]
        unresponsivePIDs = [9]
        let monitor = makeMonitor()

        monitor.evaluate()

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_cooldown_perProcessAndResetsWhenRecovered() {
        preferences.notifyHungApps = true
        apps = [RunningAppInfo(name: "Notes", pid: 5)]
        unresponsivePIDs = [5]
        let monitor = makeMonitor()

        monitor.evaluate()                                  // fires
        monitor.evaluate()                                  // still hung, inside cooldown — suppressed
        XCTAssertEqual(dispatcher.calls.count, 1)

        // The app recovers, then hangs again — the bookkeeping reset means it
        // alerts once more even within the original cooldown window.
        unresponsivePIDs = []
        monitor.evaluate()
        unresponsivePIDs = [5]
        monitor.evaluate()
        XCTAssertEqual(dispatcher.calls.count, 2)
    }
}
