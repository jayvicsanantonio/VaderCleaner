// CareScanEngineTests.swift
// Tests the concurrent scan orchestrator against fake runners: lane layout, failure isolation, skips, shared app discovery, monotonic progress, event lifecycle, and deterministic aggregation.

import XCTest
@testable import VaderCleaner

final class CareScanEngineTests: XCTestCase {

    // MARK: - Test doubles

    /// Thread-safe event recorder for the engine's @Sendable event callback.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CareScanEngine.Event] = []

        func append(_ event: CareScanEngine.Event) {
            lock.lock(); defer { lock.unlock() }
            storage.append(event)
        }

        var events: [CareScanEngine.Event] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    /// Thread-safe counter for asserting how often a runner was invoked.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// One-shot async gate: `wait()` suspends until `open()` is called.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private struct TestError: Error, LocalizedError {
        var errorDescription: String? { "test failure" }
    }

    private func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private func appInfo(_ name: String) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: "com.example.\(name)",
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: false
        )
    }

    /// Runners that all succeed with nothing found — tests override fields.
    private func emptyRunners() -> CareScanEngine.UnitRunners {
        CareScanEngine.UnitRunners(
            junk: { _ in ScanResult(items: []) },
            duplicates: { _ in [] },
            largeOldFiles: { _ in [] },
            malware: { _ in [] },
            installers: { [] },
            installedApps: { [] },
            appUpdates: { _, _ in [] },
            unusedApps: { _ in [] },
            appLeftovers: { _ in [] },
            loginItems: { [] },
            dueMaintenanceTaskIDs: { [] },
            browserPrivacy: { [] },
            healthSnapshot: { nil }
        )
    }

    private func configuration(
        units: Set<CareScanUnit> = Set(CareScanUnit.allCases),
        junkCategories: Set<ScanCategory> = Set(ScanCategory.allCases),
        malwareEngineAvailable: Bool = true
    ) -> CareScanEngine.Configuration {
        CareScanEngine.Configuration(
            enabledUnits: units,
            enabledJunkCategories: junkCategories,
            malwareEngineAvailable: malwareEngineAvailable
        )
    }

    // MARK: - Lane layout

    func test_lanes_partitionEnabledUnits_droppingEmptyLanes() {
        let lanes = CareScanEngine.lanes(for: [.systemJunk, .duplicates, .installers, .loginItems])
        XCTAssertEqual(lanes, [
            [.systemJunk],
            [.duplicates, .installers],
            [.loginItems]
        ])
    }

    func test_lanes_coverEveryUnitExactlyOnce() {
        let lanes = CareScanEngine.lanes(for: Set(CareScanUnit.allCases))
        let flattened = lanes.flatMap { $0 }
        XCTAssertEqual(flattened.count, CareScanUnit.allCases.count)
        XCTAssertEqual(Set(flattened), Set(CareScanUnit.allCases))
    }

    // MARK: - Aggregation

    func test_scan_aggregatesFindings_inKindDeclarationOrder() async {
        var runners = emptyRunners()
        runners.junk = { _ in ScanResult(items: [self.file("/cache", size: 10)]) }
        runners.malware = { _ in [MalwareThreat(filePath: URL(fileURLWithPath: "/evil"), threatName: "T")] }
        runners.loginItems = { [LoginItem(id: "a", name: "Agent", isEnabled: true)] }

        let engine = CareScanEngine(runners: runners)
        let plan = await engine.scan(configuration: configuration()) { _ in }

        XCTAssertEqual(plan.findings.map(\.kind), [.threats, .junkCleanup, .loginItems])
        XCTAssertEqual(plan.unitOutcomes[.systemJunk], .completed)
        XCTAssertEqual(plan.unitOutcomes[.malware], .completed)
        XCTAssertLessThanOrEqual(plan.startedAt, plan.finishedAt)
    }

    func test_scan_dropsEmptyFindings() async {
        let engine = CareScanEngine(runners: emptyRunners())
        let plan = await engine.scan(configuration: configuration()) { _ in }
        XCTAssertTrue(plan.findings.isEmpty)
        XCTAssertEqual(plan.unitOutcomes[.systemJunk], .completed)
    }

    func test_junkResult_filteredToEnabledCategories() async {
        var runners = emptyRunners()
        runners.junk = { _ in
            ScanResult(items: [
                self.file("/cache", size: 10, category: .userCache),
                self.file("/mail", size: 20, category: .mailAttachments)
            ])
        }
        let engine = CareScanEngine(runners: runners)
        let plan = await engine.scan(
            configuration: configuration(junkCategories: [.userCache])
        ) { _ in }

        guard case .junk(let result)? = plan.finding(.junkCleanup)?.payload else {
            return XCTFail("expected a junk finding")
        }
        XCTAssertEqual(result.items.map(\.category), [.userCache])
    }

    // MARK: - Skips

    func test_disabledUnit_skipped_runnerNeverCalled() async {
        let calls = CallCounter()
        var runners = emptyRunners()
        runners.duplicates = { _ in calls.increment(); return [] }

        let engine = CareScanEngine(runners: runners)
        let units = Set(CareScanUnit.allCases).subtracting([.duplicates])
        let plan = await engine.scan(configuration: configuration(units: units)) { _ in }

        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(plan.unitOutcomes[.duplicates], .skipped(.disabledInSettings))
    }

    func test_malwareEngineUnavailable_skipsWithReason() async {
        let calls = CallCounter()
        var runners = emptyRunners()
        runners.malware = { _ in calls.increment(); return [] }

        let engine = CareScanEngine(runners: runners)
        let plan = await engine.scan(
            configuration: configuration(malwareEngineAvailable: false)
        ) { _ in }

        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(plan.unitOutcomes[.malware], .skipped(.clamAVUnavailable))
    }

    func test_skippedUnits_emitFinishedEvents() async {
        let log = EventLog()
        let engine = CareScanEngine(runners: emptyRunners())
        let units = Set(CareScanUnit.allCases).subtracting([.browserPrivacy])
        _ = await engine.scan(configuration: configuration(units: units)) { log.append($0) }

        let skipped = log.events.contains {
            if case .unitFinished(.browserPrivacy, .skipped(.disabledInSettings), _) = $0 { return true }
            return false
        }
        XCTAssertTrue(skipped, "the checklist needs a finished event for skipped units")
    }

    // MARK: - Failure isolation

    func test_unitFailure_isIsolated() async {
        var runners = emptyRunners()
        runners.junk = { _ in throw TestError() }
        runners.malware = { _ in [MalwareThreat(filePath: URL(fileURLWithPath: "/evil"), threatName: "T")] }

        let engine = CareScanEngine(runners: runners)
        let plan = await engine.scan(configuration: configuration()) { _ in }

        XCTAssertEqual(plan.unitOutcomes[.systemJunk], .failed(message: "test failure"))
        XCTAssertNotNil(plan.finding(.threats), "other units must still land their findings")
        XCTAssertNil(plan.finding(.junkCleanup))
    }

    func test_appDiscoveryFailure_failsAllThreeAppUnits() async {
        let discoveries = CallCounter()
        var runners = emptyRunners()
        runners.installedApps = { discoveries.increment(); throw TestError() }

        let engine = CareScanEngine(runners: runners)
        let plan = await engine.scan(configuration: configuration()) { _ in }

        XCTAssertEqual(discoveries.count, 1)
        for unit in [CareScanUnit.appUpdates, .unusedApps, .appLeftovers] {
            guard case .failed = plan.unitOutcomes[unit] else {
                return XCTFail("\(unit) should fail when app discovery fails")
            }
        }
    }

    func test_appDiscovery_runsOnce_andFansOut() async {
        let discoveries = CallCounter()
        var runners = emptyRunners()
        runners.installedApps = { discoveries.increment(); return [self.appInfo("Solo")] }
        runners.appLeftovers = { bundleIDs in
            XCTAssertEqual(bundleIDs, ["com.example.Solo"])
            return []
        }
        runners.unusedApps = { apps in
            XCTAssertEqual(apps.map(\.name), ["Solo"])
            return []
        }

        let engine = CareScanEngine(runners: runners)
        _ = await engine.scan(configuration: configuration()) { _ in }

        XCTAssertEqual(discoveries.count, 1)
    }

    // MARK: - Concurrency shape

    func test_lanesRunConcurrently_junkAndMalwareOverlap() async {
        let malwareStarted = Gate()
        var runners = emptyRunners()
        // Junk cannot finish until malware has started: if lanes ran serially
        // (junk lane first, to completion) this would deadlock and time out.
        runners.junk = { _ in
            await malwareStarted.wait()
            return ScanResult(items: [])
        }
        runners.malware = { _ in
            await malwareStarted.open()
            return []
        }

        let engine = CareScanEngine(runners: runners)
        let plan = await engine.scan(
            configuration: configuration(units: [.systemJunk, .malware])
        ) { _ in }

        XCTAssertEqual(plan.unitOutcomes[.systemJunk], .completed)
        XCTAssertEqual(plan.unitOutcomes[.malware], .completed)
    }

    func test_withinALane_unitsRunStrictlySequentially() async {
        let duplicatesFinished = CallCounter()
        var runners = emptyRunners()
        runners.duplicates = { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            duplicatesFinished.increment()
            return []
        }
        runners.largeOldFiles = { _ in
            XCTAssertEqual(
                duplicatesFinished.count, 1,
                "large/old files must not start until the duplicates walk finished — they share the Downloads tree"
            )
            return []
        }

        let engine = CareScanEngine(runners: runners)
        _ = await engine.scan(
            configuration: configuration(units: [.duplicates, .largeOldFiles])
        ) { _ in }
    }

    // MARK: - Progress & events

    func test_progress_isClampedMonotonic() async {
        let log = EventLog()
        var runners = emptyRunners()
        runners.junk = { onProgress in
            onProgress(5)
            onProgress(3)   // stale tick from a superseded phase — must be dropped
            onProgress(10)
            return ScanResult(items: [])
        }

        let engine = CareScanEngine(runners: runners)
        _ = await engine.scan(configuration: configuration(units: [.systemJunk])) { log.append($0) }

        let progress = log.events.compactMap { event -> Int? in
            if case .unitProgress(.systemJunk, let count) = event { return count }
            return nil
        }
        XCTAssertEqual(progress, [5, 10])
    }

    func test_events_startedThenFinished_withFinding() async {
        let log = EventLog()
        var runners = emptyRunners()
        runners.malware = { _ in [MalwareThreat(filePath: URL(fileURLWithPath: "/evil"), threatName: "T")] }

        let engine = CareScanEngine(runners: runners)
        _ = await engine.scan(configuration: configuration(units: [.malware])) { log.append($0) }

        let malwareEvents = log.events.filter {
            switch $0 {
            case .unitStarted(let unit), .unitProgress(let unit, _), .unitFinished(let unit, _, _):
                return unit == .malware
            }
        }
        guard malwareEvents.count == 2,
              case .unitStarted = malwareEvents[0],
              case .unitFinished(_, .completed, let finding) = malwareEvents[1] else {
            return XCTFail("expected started then finished, got \(malwareEvents)")
        }
        XCTAssertEqual(finding?.kind, .threats)
    }

    // MARK: - Health snapshot

    func test_healthSnapshot_landsOnPlan_andRaisesLowDiskFinding() async {
        var runners = emptyRunners()
        let snapshot = CareHealthSnapshot(
            disk: DiskStats(usedBytes: 95, totalBytes: 100),
            memoryPressure: .nominal,
            smart: .good,
            battery: .absent
        )
        runners.healthSnapshot = { snapshot }

        let engine = CareScanEngine(runners: runners)
        let plan = await engine.scan(configuration: configuration(units: [.healthSnapshot])) { _ in }

        XCTAssertEqual(plan.health, snapshot)
        XCTAssertNotNil(plan.finding(.lowDiskSpace))
    }

    func test_healthSnapshot_comfortableDisk_raisesNoFinding() async {
        var runners = emptyRunners()
        runners.healthSnapshot = {
            CareHealthSnapshot(
                disk: DiskStats(usedBytes: 40, totalBytes: 100),
                memoryPressure: .nominal,
                smart: .good,
                battery: .absent
            )
        }

        let engine = CareScanEngine(runners: runners)
        let plan = await engine.scan(configuration: configuration(units: [.healthSnapshot])) { _ in }

        XCTAssertNotNil(plan.health)
        XCTAssertNil(plan.finding(.lowDiskSpace))
    }

    // MARK: - Cancellation

    func test_cancellation_returnsPromptly() async {
        let junkStarted = Gate()
        var runners = emptyRunners()
        runners.junk = { _ in
            await junkStarted.open()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return ScanResult(items: [])
        }

        let engine = CareScanEngine(runners: runners)
        let start = Date()
        let task = Task {
            await engine.scan(configuration: configuration(units: [.systemJunk])) { _ in }
        }
        await junkStarted.wait()
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "cancellation must tear the scan down promptly")
    }
}
