// TrashedAppMonitorTests.swift
// Verifies the trashed-app monitor notifies only for newly-trashed apps and respects the toggle.

import XCTest
@testable import VaderCleaner

@MainActor
final class TrashedAppMonitorTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.TrashedApp.\(UUID().uuidString)")!
        preferences = PreferencesStore(defaults: defaults)
        dispatcher = StubNotificationDispatcher()
    }

    private func makeMonitor() -> TrashedAppMonitor {
        TrashedAppMonitor(preferences: preferences, dispatcher: dispatcher, appLister: { [] })
    }

    func test_fires_forNewlyTrashedApp() {
        preferences.offerUninstallOnTrash = true
        let monitor = makeMonitor()

        monitor.evaluate(trashedAppNames: ["Spotify"])

        XCTAssertEqual(dispatcher.calls, [.appTrashed(appName: "Spotify")])
    }

    func test_doesNotReFire_forAlreadySeenApp() {
        preferences.offerUninstallOnTrash = true
        let monitor = makeMonitor()

        monitor.evaluate(trashedAppNames: ["Spotify"])
        monitor.evaluate(trashedAppNames: ["Spotify"])   // still there, not new

        XCTAssertEqual(dispatcher.calls.count, 1)
    }

    func test_firesForEachNewApp_acrossPolls() {
        preferences.offerUninstallOnTrash = true
        let monitor = makeMonitor()

        monitor.evaluate(trashedAppNames: ["Spotify"])
        monitor.evaluate(trashedAppNames: ["Spotify", "Slack"])

        XCTAssertEqual(dispatcher.calls, [.appTrashed(appName: "Spotify"), .appTrashed(appName: "Slack")])
    }

    func test_toggleOff_suppressesButAdvancesBaseline() {
        preferences.offerUninstallOnTrash = false
        let monitor = makeMonitor()

        // Seen while off — must not notify and must be remembered.
        monitor.evaluate(trashedAppNames: ["Spotify"])
        XCTAssertTrue(dispatcher.calls.isEmpty)

        // Turning it on later must not replay the already-present app.
        preferences.offerUninstallOnTrash = true
        monitor.evaluate(trashedAppNames: ["Spotify"])
        XCTAssertTrue(dispatcher.calls.isEmpty)

        // A genuinely new app still notifies.
        monitor.evaluate(trashedAppNames: ["Spotify", "Discord"])
        XCTAssertEqual(dispatcher.calls, [.appTrashed(appName: "Discord")])
    }
}
