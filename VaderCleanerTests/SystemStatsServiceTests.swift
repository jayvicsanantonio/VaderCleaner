// SystemStatsServiceTests.swift
// Tests that the system-stats data layer reports plausible values and that its polling timer fans them out.

import XCTest
import Combine
@testable import VaderCleaner

/// Exercises `SystemStatsService` and its supporting value types.
///
/// The service reads live numbers from mach / IOKit / `FileManager` against
/// the host running the test, so assertions are framed as **invariants** —
/// "is this a plausible value?" — rather than fixed expectations. The CI box
/// is the developer's laptop, which means we can't drive memory into a
/// `.critical` pressure state or unplug the battery; what we can do is pin the
/// shape of the output (ranges, non-negativity, ordering) and verify the timer
/// fans publishes out as expected.
@MainActor
final class SystemStatsServiceTests: XCTestCase {

    // MARK: - MemoryPressureLevel

    /// `MemoryPressureLevel` is the public surface every Health Monitor color
    /// state binds to, so the four representative ratios (well below the low
    /// threshold, just above it, just above the high threshold, and a saturated
    /// near-1.0) lock the bucket boundaries the UI depends on.
    func test_memoryPressureLevel_thresholds() {
        XCTAssertEqual(MemoryPressureLevel(usedRatio: 0.30), .nominal)
        XCTAssertEqual(MemoryPressureLevel(usedRatio: 0.80), .fair)
        XCTAssertEqual(MemoryPressureLevel(usedRatio: 0.90), .critical)
        XCTAssertEqual(MemoryPressureLevel(usedRatio: 0.99), .critical)
    }

    /// Pin the inclusive/exclusive semantics at the bucket edges. A future
    /// refactor flipping `<` to `<=` would silently shift the boundary cases —
    /// these assertions catch that.
    func test_memoryPressureLevel_boundariesAreLowerInclusive() {
        // 0.70 is exactly the fair threshold: the `<` comparison flips to fair.
        XCTAssertEqual(MemoryPressureLevel(usedRatio: 0.70), .fair)
        // 0.85 is exactly the critical threshold: the `<` comparison flips to critical.
        XCTAssertEqual(MemoryPressureLevel(usedRatio: 0.85), .critical)
    }

    /// `MemoryStats.pressureLevel` must derive from `usedBytes / totalBytes` and
    /// match the same buckets — the property is what the UI binds to, not the
    /// raw enum initializer.
    func test_memoryStats_pressureLevel_derivedFromRatio() {
        let nominal = MemoryStats(usedBytes: 30, totalBytes: 100)
        let fair = MemoryStats(usedBytes: 75, totalBytes: 100)
        let critical = MemoryStats(usedBytes: 90, totalBytes: 100)
        XCTAssertEqual(nominal.pressureLevel, .nominal)
        XCTAssertEqual(fair.pressureLevel, .fair)
        XCTAssertEqual(critical.pressureLevel, .critical)
    }

    /// A zero-byte total can occur transiently before the first refresh
    /// populates `ramUsage`. We must not crash on the divide.
    func test_memoryStats_pressureLevel_zeroTotalIsNominal() {
        let stats = MemoryStats(usedBytes: 0, totalBytes: 0)
        XCTAssertEqual(stats.pressureLevel, .nominal)
    }

    // MARK: - SystemStatsService — cheap stats

    func test_cpuUsage_isInUnitInterval() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        // First refresh seeds the baseline (returns 0); second refresh produces
        // a real delta. Both must lie in [0, 1].
        service.refresh()
        XCTAssertGreaterThanOrEqual(service.cpuUsage, 0.0)
        XCTAssertLessThanOrEqual(service.cpuUsage, 1.0)
        service.refresh()
        XCTAssertGreaterThanOrEqual(service.cpuUsage, 0.0)
        XCTAssertLessThanOrEqual(service.cpuUsage, 1.0)
    }

    func test_ramUsage_hasPlausibleByteCounts() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        service.refresh()
        XCTAssertGreaterThan(service.ramUsage.totalBytes, 0)
        XCTAssertGreaterThan(service.ramUsage.usedBytes, 0)
        XCTAssertLessThanOrEqual(service.ramUsage.usedBytes, service.ramUsage.totalBytes)
    }

    /// The pressureLevel discriminator is what the UI keys color off of, so we
    /// pin its inhabitancy in the live read — even though we can't force the
    /// host into `.critical` from a unit test.
    func test_ramUsage_pressureLevel_isOneOfThreeCases() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        service.refresh()
        let level = service.ramUsage.pressureLevel
        XCTAssertTrue(
            [.nominal, .fair, .critical].contains(level),
            "Unexpected MemoryPressureLevel: \(level)"
        )
    }

    func test_diskSpace_hasPlausibleByteCounts() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        service.refresh()
        XCTAssertGreaterThan(service.diskSpace.totalBytes, 0)
        XCTAssertGreaterThan(service.diskSpace.usedBytes, 0)
        XCTAssertLessThanOrEqual(service.diskSpace.usedBytes, service.diskSpace.totalBytes)
    }

    /// Battery may be `nil` on a desktop or absent on a Mac mini. When present,
    /// cycleCount is non-negative and the condition string is not empty. This
    /// is the "either nil or plausible" invariant — tests can't force the
    /// nil branch on a laptop runner.
    func test_batteryHealth_eitherNilOrPlausible() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        service.refresh()
        if let battery = service.batteryHealth {
            XCTAssertGreaterThanOrEqual(battery.cycleCount, 0)
            XCTAssertGreaterThanOrEqual(battery.maxCapacityPercent, 0.0)
            XCTAssertFalse(battery.condition.isEmpty)
        }
        // Else: no battery present, which is a valid state — nothing to assert.
    }

    // MARK: - Timer wiring

    /// "Updates stats on a timer" — the spec test from plan.md. We don't mock
    /// `Timer` itself; instead we configure a tiny interval, subscribe to the
    /// `objectWillChange` publisher *before* starting, and verify it fires
    /// within a deadline. That proves the timer fans publishes out without
    /// coupling the test to any internal scheduling abstraction.
    ///
    /// The service is built with `autostart: false` and started manually
    /// after the sink is attached. Otherwise the auto-fired
    /// `refreshDeviceHealth()` from the init can satisfy this expectation
    /// via its background subprocess path even when the cheap-stats timer is
    /// broken — making the test pass spuriously.
    func test_timer_publishesUpdates_whenStarted() {
        let service = SystemStatsService(interval: 0.05, autostart: false)
        let didPublish = expectation(description: "service publishes on timer tick")

        var fired = false
        let cancellable: AnyCancellable = service.objectWillChange.sink {
            // First publish wins; subsequent ticks would over-fulfil the
            // expectation otherwise (which XCTest treats as a failure).
            guard !fired else { return }
            fired = true
            didPublish.fulfill()
        }

        service.start()
        wait(for: [didPublish], timeout: 2.0)
        cancellable.cancel()
        service.stop()
    }

    func test_stop_haltsFurtherUpdates() {
        let service = SystemStatsService(interval: 0.05, autostart: false)
        // Let one tick land so the baseline is established. Sink-then-start
        // ordering guarantees the first publish we observe is timer-driven,
        // not the slow-path device-health refresh that the autostart init
        // would otherwise kick off.
        let firstTick = expectation(description: "first tick")
        var firstFired = false
        var cancellable: AnyCancellable? = service.objectWillChange.sink {
            guard !firstFired else { return }
            firstFired = true
            firstTick.fulfill()
        }
        service.start()
        wait(for: [firstTick], timeout: 2.0)
        cancellable?.cancel()

        service.stop()

        // After stop(), no further objectWillChange should fire within the
        // window. We use a manual counter rather than an inverted
        // XCTestExpectation because the timer can otherwise emit several
        // events before XCTest unwinds the wait, over-fulfilling the
        // expectation and tripping its internal assertion.
        var ticksAfterStop = 0
        cancellable = service.objectWillChange.sink {
            ticksAfterStop += 1
        }
        let settle = expectation(description: "settle window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settle.fulfill()
        }
        wait(for: [settle], timeout: 1.0)
        cancellable?.cancel()
        XCTAssertEqual(ticksAfterStop, 0, "Service emitted \(ticksAfterStop) updates after stop()")
    }
}
