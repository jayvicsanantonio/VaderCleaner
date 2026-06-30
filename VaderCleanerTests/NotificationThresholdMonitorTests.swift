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
        case lowDisk(freeBytes: Int64)
        case highRAM(pressureLevel: String)
        case malware(threatName: String)
        case largeFiles(count: Int, totalSize: Int64)
        case trashSize(sizeBytes: Int64)
        case deviceBatteryLow(deviceName: String, percent: Int)
        case driveConnected(volumeName: String)
        case overfilledDrive(volumeName: String, freeBytes: Int64, totalBytes: Int64)
        case appTrashed(appName: String)
        case hungApp(appName: String)
    }

    private(set) var calls: [Call] = []

    func requestPermission() async { calls.append(.requestPermission) }
    func sendLowDiskNotification(freeBytes: Int64) {
        calls.append(.lowDisk(freeBytes: freeBytes))
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
    func sendTrashSizeNotification(sizeBytes: Int64) {
        calls.append(.trashSize(sizeBytes: sizeBytes))
    }
    func sendDeviceBatteryLowNotification(deviceName: String, percent: Int) {
        calls.append(.deviceBatteryLow(deviceName: deviceName, percent: percent))
    }
    func sendDriveConnectedNotification(volumeName: String) {
        calls.append(.driveConnected(volumeName: volumeName))
    }
    func sendOverfilledDriveNotification(volumeName: String, freeBytes: Int64, totalBytes: Int64) {
        calls.append(.overfilledDrive(volumeName: volumeName, freeBytes: freeBytes, totalBytes: totalBytes))
    }
    func sendAppTrashedNotification(appName: String) {
        calls.append(.appTrashed(appName: appName))
    }
    func sendHungAppNotification(appName: String) {
        calls.append(.hungApp(appName: appName))
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
    ///
    /// `assumesPermissionResolved: true` keeps the existing dispatch tests
    /// synchronous — they don't care about the permission gate, only the
    /// toggle / threshold / cooldown logic. Tests that *do* care about the
    /// gate construct their own monitor with the default (`false`).
    private func makeMonitor() -> NotificationThresholdMonitor {
        NotificationThresholdMonitor(
            stats: stats,
            preferences: preferences,
            dispatcher: dispatcher,
            cooldown: 5 * 60,
            now: { [unowned self] in self.virtualNow },
            assumesPermissionResolved: true
        )
    }

    /// Builds a `DiskStats` with the requested free gigabytes (decimal GB).
    /// `total` is held constant at 1 TB so the math is easy to read in test bodies.
    private func disk(freeGB: Int) -> DiskStats {
        let total: UInt64 = 1_000_000_000_000
        let free = UInt64(freeGB) * 1_000_000_000
        let used = total > free ? total - free : 0
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

    func test_lowDisk_firesWhenFreeBelowThresholdAndToggleOn() {
        preferences.notifyLowDisk = true
        preferences.diskFreeThresholdGB = 10
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freeGB: 8))

        XCTAssertEqual(dispatcher.calls.count, 1)
        if case .lowDisk(let freeBytes)? = dispatcher.calls.first {
            // Free bytes pass through unchanged so the notification can format
            // them however it wants (8 decimal GB here).
            XCTAssertEqual(freeBytes, 8_000_000_000)
        } else {
            XCTFail("Expected a .lowDisk call, got \(dispatcher.calls)")
        }
    }

    func test_lowDisk_doesNotFireWhenToggleOff() {
        preferences.notifyLowDisk = false
        preferences.diskFreeThresholdGB = 10
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freeGB: 5))

        XCTAssertTrue(dispatcher.calls.isEmpty,
                      "Notification must respect the user's preference toggle")
    }

    func test_lowDisk_doesNotFireAboveThreshold() {
        preferences.notifyLowDisk = true
        preferences.diskFreeThresholdGB = 10
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freeGB: 15))

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_lowDisk_doesNotReFireWithinCooldown() {
        preferences.notifyLowDisk = true
        preferences.diskFreeThresholdGB = 10
        let monitor = makeMonitor()

        // First crossing fires.
        monitor.evaluate(disk: disk(freeGB: 8))
        // 4:59 later — still under the 5-minute cooldown.
        virtualNow = virtualNow.addingTimeInterval(299)
        monitor.evaluate(disk: disk(freeGB: 6))

        XCTAssertEqual(dispatcher.calls.count, 1,
                       "Second sample inside the cooldown must not re-trigger")
    }

    func test_lowDisk_reFiresAfterCooldownElapses() {
        preferences.notifyLowDisk = true
        preferences.diskFreeThresholdGB = 10
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freeGB: 8))
        // Step past the 5-minute boundary.
        virtualNow = virtualNow.addingTimeInterval(301)
        monitor.evaluate(disk: disk(freeGB: 6))

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
        preferences.diskFreeThresholdGB = 10
        let monitor = makeMonitor()

        monitor.evaluate(disk: disk(freeGB: 5))
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

    // MARK: - Permission gate

    /// A threshold reading observed before `requestPermission()` has resolved
    /// must not dispatch and must not stamp the cooldown. Stamping a 5-minute
    /// cooldown against a notification the system would silently drop would
    /// suppress the next eligible alert immediately after the user grants
    /// permission.
    func test_doesNotDispatchBeforePermissionResolved() {
        preferences.notifyLowDisk = true
        preferences.diskFreeThresholdGB = 10
        let monitor = NotificationThresholdMonitor(
            stats: stats,
            preferences: preferences,
            dispatcher: dispatcher,
            cooldown: 5 * 60,
            now: { [unowned self] in self.virtualNow }
            // assumesPermissionResolved defaults to false
        )

        monitor.evaluate(disk: disk(freeGB: 5))
        monitor.evaluate(ram: memory(forLevel: .critical))
        monitor.triggerMalwareDetected(threatName: "X")
        monitor.triggerLargeFilesFound(count: 1, totalSize: 1)

        XCTAssertTrue(dispatcher.calls.isEmpty,
                      "No notifications should fire before requestPermission resolves")
    }

    /// After `requestPermission()` resolves, the same reading that was
    /// suppressed earlier must dispatch — and the cooldown table must still
    /// be empty so the post-grant alert fires immediately rather than waiting
    /// out a stale stamp.
    func test_dispatchesImmediatelyAfterPermissionResolves() async {
        preferences.notifyLowDisk = true
        preferences.notifyHighRAM = true
        preferences.diskFreeThresholdGB = 10
        let monitor = NotificationThresholdMonitor(
            stats: stats,
            preferences: preferences,
            dispatcher: dispatcher,
            cooldown: 5 * 60,
            now: { [unowned self] in self.virtualNow }
        )

        // Pre-resolution: gate suppresses everything.
        monitor.evaluate(disk: disk(freeGB: 5))
        XCTAssertTrue(dispatcher.calls.filter { !isPermissionRequest($0) }.isEmpty)

        // Resolve.
        await monitor.requestPermission()

        // Post-resolution: dispatch fires.
        monitor.evaluate(disk: disk(freeGB: 5))

        let dispatches = dispatcher.calls.filter { !isPermissionRequest($0) }
        XCTAssertEqual(dispatches.count, 1, "Post-grant low-disk alert should fire on the next reading")
        if case .lowDisk(let freeBytes) = dispatches.first {
            XCTAssertEqual(freeBytes, 5_000_000_000)
        } else {
            XCTFail("Expected a .lowDisk dispatch, got \(dispatches)")
        }
    }

    /// Filters out the bookkeeping `.requestPermission` entries so the
    /// gate tests can assert only on actual notification dispatches.
    private func isPermissionRequest(_ call: StubNotificationDispatcher.Call) -> Bool {
        if case .requestPermission = call { return true }
        return false
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
