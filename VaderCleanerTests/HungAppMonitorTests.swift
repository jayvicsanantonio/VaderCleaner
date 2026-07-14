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
    private var probeState: ProbeState!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.HungApp.\(UUID().uuidString)")!
        preferences = PreferencesStore(defaults: defaults)
        dispatcher = StubNotificationDispatcher()
        apps = []
        probeState = ProbeState()
    }

    private func makeMonitor() -> HungAppMonitor {
        let state = probeState!
        return HungAppMonitor(
            preferences: preferences,
            dispatcher: dispatcher,
            appLister: { [unowned self] in self.apps },
            isResponsive: { pid in state.probe(pid) },
            cooldown: 60 * 60,
            now: { [unowned self] in self.virtualNow }
        )
    }

    func test_fires_forUnresponsiveAppWhenOn() async {
        preferences.notifyHungApps = true
        apps = [RunningAppInfo(name: "Safari", pid: 42)]
        probeState.unresponsive = [42]
        let monitor = makeMonitor()

        await monitor.evaluate()

        XCTAssertEqual(dispatcher.calls, [.hungApp(appName: "Safari")])
    }

    func test_doesNotFire_forResponsiveApp() async {
        preferences.notifyHungApps = true
        apps = [RunningAppInfo(name: "Mail", pid: 7)]
        let monitor = makeMonitor()

        await monitor.evaluate()

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_doesNotFire_whenToggleOff() async {
        preferences.notifyHungApps = false
        apps = [RunningAppInfo(name: "Xcode", pid: 9)]
        probeState.unresponsive = [9]
        let monitor = makeMonitor()

        await monitor.evaluate()

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_cooldown_perProcessAndResetsWhenRecovered() async {
        preferences.notifyHungApps = true
        apps = [RunningAppInfo(name: "Notes", pid: 5)]
        probeState.unresponsive = [5]
        let monitor = makeMonitor()

        await monitor.evaluate()                            // fires
        await monitor.evaluate()                            // still hung, inside cooldown — suppressed
        XCTAssertEqual(dispatcher.calls.count, 1)

        // The app recovers, then hangs again — the bookkeeping reset means it
        // alerts once more even within the original cooldown window.
        probeState.unresponsive = []
        await monitor.evaluate()
        probeState.unresponsive = [5]
        await monitor.evaluate()
        XCTAssertEqual(dispatcher.calls.count, 2)
    }

    /// Each AX probe can block up to its 0.5s messaging timeout, so an app
    /// must be probed exactly once per pass — the old fire loop plus cleanup
    /// loop probed everything twice, doubling the worst-case stall.
    func test_probesEachAppExactlyOncePerPass() async {
        preferences.notifyHungApps = true
        apps = [
            RunningAppInfo(name: "Safari", pid: 42),
            RunningAppInfo(name: "Mail", pid: 7),
        ]
        probeState.unresponsive = [42]
        let monitor = makeMonitor()

        await monitor.evaluate()

        XCTAssertEqual(
            probeState.counts,
            [42: 1, 7: 1],
            "One probe per app per pass — a second probe doubles the potential main-thread stall"
        )
    }

    /// The probe pass must run off the main thread: a hung app holds each
    /// probe for the full messaging timeout, which on the main thread was a
    /// repeating half-second hang every poll.
    func test_probesRunOffTheMainThread() async {
        preferences.notifyHungApps = true
        apps = [RunningAppInfo(name: "Safari", pid: 42)]
        let monitor = makeMonitor()

        await monitor.evaluate()

        XCTAssertEqual(probeState.sawMainThread, false)
    }

    /// A probe pass over many hung apps can outlast the poll interval
    /// (0.5s worst case per app), so an overlapping pass must be skipped —
    /// otherwise both passes fire before either records its cooldowns.
    func test_overlappingPassIsSkippedWhileProbeInFlight() async {
        preferences.notifyHungApps = true
        apps = [RunningAppInfo(name: "Slow", pid: 3)]
        probeState.unresponsive = [3]
        let gate = DispatchSemaphore(value: 0)
        probeState.onProbe = { gate.wait() }
        let monitor = makeMonitor()

        let first = Task { await monitor.evaluate() }
        // Let the first pass reach its (gated) probe before overlapping it.
        try? await Task.sleep(for: .milliseconds(100))
        await monitor.evaluate()
        gate.signal()
        await first.value

        XCTAssertEqual(probeState.counts, [3: 1], "The overlapped pass must skip, not re-probe")
        XCTAssertEqual(dispatcher.calls.count, 1, "The app fires once, not once per overlapping pass")
    }
}

/// Shared mutable probe fake, capturable by the monitor's `@Sendable` probe.
/// The unchecked conformance is safe here: probes within one pass run
/// sequentially, and the tests mutate `unresponsive` only between awaited
/// passes.
private final class ProbeState: @unchecked Sendable {
    var unresponsive: Set<pid_t> = []
    var counts: [pid_t: Int] = [:]
    var sawMainThread: Bool?
    /// Ran inside each probe — lets the overlap test hold a pass open.
    var onProbe: (() -> Void)?

    func probe(_ pid: pid_t) -> Bool {
        counts[pid, default: 0] += 1
        sawMainThread = Thread.isMainThread
        onProbe?()
        return !unresponsive.contains(pid)
    }
}
