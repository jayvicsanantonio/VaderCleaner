// TrashedAppMonitorTests.swift
// Verifies the trashed-app monitor notifies only for newly-trashed apps, respects the toggle, and never lists the Trash on the main thread.

import Testing
import XCTest
@testable import VaderCleanerCore

@MainActor
final class TrashedAppMonitorTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!

    override func setUp() async throws {
        try await super.setUp()
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

/// The Trash can hold enough items that listing it takes many seconds, so these
/// pin that it never happens on the main thread, and that moving it off doesn't
/// let a stale listing replay notifications for apps already seen.
@MainActor
@Suite
struct TrashedAppMonitorListingTests {

    private let preferences: PreferencesStore
    private let dispatcher = StubNotificationDispatcher()

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "VaderCleanerTests.TrashedAppListing.\(UUID().uuidString)"))
        preferences = PreferencesStore(defaults: defaults)
        preferences.offerUninstallOnTrash = true
    }

    private func makeMonitor(appLister: @escaping TrashedAppMonitor.AppLister) -> TrashedAppMonitor {
        TrashedAppMonitor(preferences: preferences, dispatcher: dispatcher, appLister: appLister)
    }

    @Test func start_listsTheTrashOffTheMainThread() async {
        let listedOnMain = TestBox<[Bool]>([])
        let monitor = makeMonitor {
            listedOnMain.value.append(Thread.isMainThread)
            return []
        }
        defer { monitor.stop() }

        monitor.start()

        #expect(await pollUntil { !listedOnMain.value.isEmpty })
        #expect(listedOnMain.value == [false])
    }

    @Test func poll_listsTheTrashOffTheMainThread() async {
        let listedOnMain = TestBox<[Bool]>([])
        let monitor = makeMonitor {
            listedOnMain.value.append(Thread.isMainThread)
            return []
        }

        monitor.poll()

        #expect(await pollUntil { !listedOnMain.value.isEmpty })
        #expect(listedOnMain.value == [false])
    }

    @Test func start_primesTheBaseline_soAppsAlreadyInTheTrashDoNotNotify() async {
        let listed = TestBox(0)
        let monitor = makeMonitor {
            listed.value += 1
            return ["Spotify"]
        }
        defer { monitor.stop() }

        monitor.start()
        #expect(await pollUntil { listed.value == 1 })
        #expect(await pollUntil { monitor.hasPrimedBaseline })

        monitor.evaluate(trashedAppNames: ["Spotify"])
        #expect(dispatcher.calls.isEmpty)
    }

    @Test func stop_discardsAListingStillInFlight() async {
        let gate = CallGate()
        let monitor = makeMonitor {
            gate.hold()
            return ["Spotify"]
        }

        monitor.start()
        #expect(await pollUntil { gate.isHolding })
        monitor.stop()
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))

        // The abandoned listing must not have become the baseline.
        monitor.evaluate(trashedAppNames: ["Spotify"])
        #expect(dispatcher.calls == [.appTrashed(appName: "Spotify")])
    }

    @Test func changesDuringAListing_coalesceIntoOneFollowUp() async {
        // A big cleanup writes to the Trash thousands of times. Overlapping
        // listings could finish out of order and replay apps already seen.
        let gate = CallGate()
        let listed = TestBox(0)
        let monitor = makeMonitor {
            listed.value += 1
            if listed.value == 1 { gate.hold() }
            return ["Spotify"]
        }

        monitor.poll()
        #expect(await pollUntil { listed.value == 1 })
        monitor.poll()
        monitor.poll()
        monitor.poll()
        gate.open()

        #expect(await pollUntil { listed.value == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(listed.value == 2)
        #expect(dispatcher.calls == [.appTrashed(appName: "Spotify")])
    }
}
