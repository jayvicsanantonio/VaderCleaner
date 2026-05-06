// NotificationThresholdMonitorTests.swift
// Tests that the threshold monitor dispatches notifications only when toggles allow it and respects the per-kind cooldown.

import XCTest
@testable import VaderCleaner

/// Records `NotificationDispatching` calls in order for test assertions. Each
/// test gets a fresh stub so call counts and recorded payloads do not leak.
@MainActor
final class StubNotificationDispatcher: NotificationDispatching {

    enum Call: Equatable {
        case requestPermission
        case lowDisk(freePercent: Double)
        case highRAM(pressureLevel: String)
        case malware(threatName: String)
        case largeFiles(count: Int, totalSize: Int64)
    }

    private(set) var calls: [Call] = []

    func requestPermission() async { calls.append(.requestPermission) }
    func sendLowDiskNotification(freePercent: Double) {
        calls.append(.lowDisk(freePercent: freePercent))
    }
    func sendHighRAMNotification(pressureLevel: String) {
        calls.append(.highRAM(pressureLevel: pressureLevel))
    }
    func sendMalwareDetectedNotification(threatName: String) {
        calls.append(.malware(threatName: threatName))
    }
    func sendLargeFilesFoundNotification(count: Int, totalSize: Int64) {
        calls.append(.largeFiles(count: count, totalSize: totalSize))
    }
}

@MainActor
final class NotificationThresholdMonitorTests: XCTestCase {

    // MARK: - Test scaffolding

    private var preferences: PreferencesStore!
    private var stats: SystemStatsService!
    private var dispatcher: StubNotificationDispatcher!
    /// Mutable virtual clock so tests can advance time across the cooldown
    /// boundary without sleeping.
    private var virtualNow: Date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        let suite = "VaderCleanerTests.NotificationThresholdMonitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        preferences = PreferencesStore(defaults: defaults)
        // autostart: false so no real timer fires during the test — every
        // evaluation goes through `evaluate(disk:)` / `evaluate(ram:)` directly.
        stats = SystemStatsService(interval: 60, autostart: false)
        dispatcher = StubNotificationDispatcher()
        virtualNow = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDown() {
        preferences = nil
        stats = nil
        dispatcher = nil
        super.tearDown()
    }

    /// Fresh monitor pinned to the test's virtual clock. Tests that need to
    /// advance time mutate `virtualNow` between calls.
    private func makeMonitor() -> NotificationThresholdMonitor {
        NotificationThresholdMonitor(
            stats: stats,
            preferences: preferences,
            dispatcher: dispatcher,
            cooldown: 5 * 60,
            now: { [unowned self] in self.virtualNow }
        )
    }

    /// Builds a `DiskStats` with the requested free percentage. `total` is held
    /// constant at 1 TB so the math is easy to read in test bodies.
    private func disk(freePercent: Double) -> DiskStats {
        let total: UInt64 = 1_000_000_000_000
        let free = UInt64(Double(total) * (freePercent / 100.0))
        let used = total - free
        return DiskStats(usedBytes: used, totalBytes: total)
    }

    /// Builds a `MemoryStats` whose `pressureLevel` matches the supplied bucket.
    /// The constructor takes raw bytes; deriving them from a target ratio keeps
    /// tests honest about which bucket they're exercising.
    private func memory(forLevel level: MemoryPressureLevel) -> MemoryStats {
        let total: UInt64 = 16_000_000_000
        let ratio: Double
        switch level {
        case .nominal: ratio = 0.30
        case .fair: ratio = 0.75
        case .critical: ratio = 0.90
        }
        return MemoryStats(usedBytes: UInt64(Double(total) * ratio), totalBytes: total)
    }

    // MARK: - Low-disk dispatch

    func test_lowDisk_firesWhenFreePercentBelowThresholdAndToggleOn() {
        preferences.notifyLowDisk = true
        preferences.diskSpaceThresholdPercent = 10.0
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freePercent: 8.0))

        XCTAssertEqual(dispatcher.calls.count, 1)
        if case .lowDisk(let freePercent)? = dispatcher.calls.first {
            // Free percent passed through unchanged so the notification can
            // format it however it wants.
            XCTAssertEqual(freePercent, 8.0, accuracy: 0.01)
        } else {
            XCTFail("Expected a .lowDisk call, got \(dispatcher.calls)")
        }
    }

    func test_lowDisk_doesNotFireWhenToggleOff() {
        preferences.notifyLowDisk = false
        preferences.diskSpaceThresholdPercent = 10.0
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freePercent: 5.0))

        XCTAssertTrue(dispatcher.calls.isEmpty,
                      "Notification must respect the user's preference toggle")
    }

    func test_lowDisk_doesNotFireAboveThreshold() {
        preferences.notifyLowDisk = true
        preferences.diskSpaceThresholdPercent = 10.0
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freePercent: 15.0))

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_lowDisk_doesNotReFireWithinCooldown() {
        preferences.notifyLowDisk = true
        preferences.diskSpaceThresholdPercent = 10.0
        let monitor = makeMonitor()

        // First crossing fires.
        monitor.evaluate(disk: disk(freePercent: 8.0))
        // 4:59 later — still under the 5-minute cooldown.
        virtualNow = virtualNow.addingTimeInterval(299)
        monitor.evaluate(disk: disk(freePercent: 6.0))

        XCTAssertEqual(dispatcher.calls.count, 1,
                       "Second sample inside the cooldown must not re-trigger")
    }

    func test_lowDisk_reFiresAfterCooldownElapses() {
        preferences.notifyLowDisk = true
        preferences.diskSpaceThresholdPercent = 10.0
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freePercent: 8.0))
        // Step past the 5-minute boundary.
        virtualNow = virtualNow.addingTimeInterval(301)
        monitor.evaluate(disk: disk(freePercent: 6.0))

        XCTAssertEqual(dispatcher.calls.count, 2)
    }

    // MARK: - High-RAM dispatch

    func test_highRAM_firesOnCritical() {
        preferences.notifyHighRAM = true
        let monitor = makeMonitor()

        monitor.evaluate(ram: memory(forLevel: .critical))

        XCTAssertEqual(dispatcher.calls.count, 1)
        if case .highRAM(let level)? = dispatcher.calls.first {
            XCTAssertFalse(level.isEmpty)
        } else {
            XCTFail("Expected a .highRAM call, got \(dispatcher.calls)")
        }
    }

    func test_highRAM_doesNotFireOnFairOrNominal() {
        preferences.notifyHighRAM = true
        let monitor = makeMonitor()

        monitor.evaluate(ram: memory(forLevel: .nominal))
        monitor.evaluate(ram: memory(forLevel: .fair))

        XCTAssertTrue(dispatcher.calls.isEmpty,
                      "Only critical pressure should trigger the notification")
    }

    func test_highRAM_doesNotFireWhenToggleOff() {
        preferences.notifyHighRAM = false
        let monitor = makeMonitor()

        monitor.evaluate(ram: memory(forLevel: .critical))

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_highRAM_doesNotReFireWithinCooldown() {
        preferences.notifyHighRAM = true
        let monitor = makeMonitor()

        monitor.evaluate(ram: memory(forLevel: .critical))
        virtualNow = virtualNow.addingTimeInterval(60)
        monitor.evaluate(ram: memory(forLevel: .critical))

        XCTAssertEqual(dispatcher.calls.count, 1)
    }

    // MARK: - Cooldowns are independent per kind

    func test_cooldownsAreIndependentPerKind() {
        preferences.notifyLowDisk = true
        preferences.notifyHighRAM = true
        preferences.diskSpaceThresholdPercent = 10.0
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freePercent: 5.0))
        // Still inside the disk cooldown, but RAM has its own clock.
        monitor.evaluate(ram: memory(forLevel: .critical))

        XCTAssertEqual(dispatcher.calls.count, 2,
                       "Disk and RAM cooldowns must not share state")
    }

    // MARK: - Malware + large-files trigger paths

    func test_malware_firesWhenToggleOnAndCooldownElapsed() {
        preferences.notifyMalwareFound = true
        let monitor = makeMonitor()

        monitor.triggerMalwareDetected(threatName: "Eicar-Test-Signature")

        XCTAssertEqual(dispatcher.calls,
                       [.malware(threatName: "Eicar-Test-Signature")])
    }

    func test_malware_doesNotFireWhenToggleOff() {
        preferences.notifyMalwareFound = false
        let monitor = makeMonitor()

        monitor.triggerMalwareDetected(threatName: "X")

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_largeFiles_firesAndRespectsCooldown() {
        preferences.notifyLargeFilesFound = true
        let monitor = makeMonitor()

        monitor.triggerLargeFilesFound(count: 5, totalSize: 1_000_000_000)
        // Inside cooldown — no second call.
        virtualNow = virtualNow.addingTimeInterval(60)
        monitor.triggerLargeFilesFound(count: 7, totalSize: 2_000_000_000)

        XCTAssertEqual(dispatcher.calls.count, 1)
    }
}
