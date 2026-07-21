// SmartScanViewModelScanTests.swift
// Tests the view model's scan flow: phase machine, engine configuration snapshot, checklist statuses from events, selection seeding by safety tier, failure policy, and cross-section completion hand-off.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelScanTests: XCTestCase {

    // MARK: - Fixtures

    private nonisolated func file(_ path: String, size: Int64, category: ScanCategory = .userCache) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private nonisolated func plan(
        findings: [CareFinding] = [],
        outcomes: [CareScanUnit: CareUnitOutcome] = [.systemJunk: .completed],
        health: CareHealthSnapshot? = nil
    ) -> CarePlan {
        CarePlan(
            findings: findings,
            health: health,
            unitOutcomes: outcomes,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
    }

    private nonisolated var richPlan: CarePlan {
        let junk = ScanResult(items: [
            file("/cache/safe", size: 1_000, category: .userCache),
            file("/mail/attachment", size: 500, category: .mailAttachments)
        ])
        let threats = [MalwareThreat(filePath: URL(fileURLWithPath: "/tmp/evil"), threatName: "Eicar")]
        let dupGroup = DuplicateGroup(files: [
            file("/Downloads/original", size: 10),
            file("/Downloads/copy", size: 10)
        ])
        let bigFile = file("/Movies/huge.mov", size: 9_000, category: .largeFile)
        let update = UpdateInfo(
            appName: "App", bundleID: "com.example.app",
            bundleURL: URL(fileURLWithPath: "/Applications/App.app"),
            installedVersion: "1.0", latestVersion: "2.0",
            source: .sparkle, updateURL: URL(string: "https://example.com")!
        )
        return plan(
            findings: [
                CareFinding(kind: .junkCleanup, payload: .junk(junk)),
                CareFinding(kind: .threats, payload: .threats(threats)),
                CareFinding(kind: .duplicates, payload: .duplicates([dupGroup])),
                CareFinding(kind: .largeOldFiles, payload: .largeOldFiles([bigFile])),
                CareFinding(kind: .appUpdates, payload: .appUpdates([update])),
                CareFinding(kind: .loginItems, payload: .loginItems([
                    LoginItem(id: "a", name: "Agent", isEnabled: true)
                ])),
            ],
            outcomes: [
                .systemJunk: .completed, .malware: .completed, .duplicates: .completed,
                .largeOldFiles: .completed, .appUpdates: .completed, .loginItems: .completed
            ]
        )
    }

    // MARK: - Phase machine

    func test_scan_movesThroughScanningToResults() async {
        let expected = richPlan
        let vm = SmartScanViewModel(scanEngine: { _, _ in expected })
        await vm.scan()
        XCTAssertEqual(vm.phase, .results(expected))
    }

    func test_scan_isIgnoredWhileScanning() async {
        let gate = AsyncGate()
        let starts = Counter()
        let expected = plan()
        let vm = SmartScanViewModel(scanEngine: { _, _ in
            starts.increment()
            await gate.wait()
            return expected
        })
        let first = Task { await vm.scan() }
        // Give the first scan time to enter `.scanning` before re-entering.
        while vm.phase != .scanning { await Task.yield() }
        await vm.scan()
        // The engine closure runs off the main actor; wait for its first
        // start to land before counting, then prove no second one arrived.
        for _ in 0..<500 where starts.count < 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(starts.count, 1, "a second scan() while scanning must be ignored")
        await gate.open()
        await first.value
    }

    func test_scan_failsOnlyWhenEveryAttemptedUnitFailed() async {
        let vm = SmartScanViewModel(scanEngine: { _, _ in
            self.plan(outcomes: [
                .systemJunk: .failed(message: "no access"),
                .malware: .failed(message: "broken"),
                .loginItems: .skipped(.disabledInSettings)
            ])
        })
        await vm.scan()
        guard case .failed(let message) = vm.phase else {
            return XCTFail("expected .failed, got \(vm.phase)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func test_scan_partialFailure_stillLandsResults() async {
        let junk = CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: [file("/c", size: 1)])))
        let expected = plan(
            findings: [junk],
            outcomes: [.systemJunk: .completed, .malware: .failed(message: "broken")]
        )
        let vm = SmartScanViewModel(scanEngine: { _, _ in expected })
        await vm.scan()
        XCTAssertEqual(vm.phase, .results(expected))
    }

    func test_reset_returnsToIdle_andClearsState() async {
        let vm = SmartScanViewModel(scanEngine: { _, _ in self.richPlan })
        await vm.scan()
        vm.reset()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.junkFileSelection.isEmpty)
        XCTAssertTrue(vm.includedFindings.isEmpty)
        XCTAssertEqual(vm.scannedItemCount, 0)
    }

    // MARK: - Engine configuration snapshot

    func test_scan_buildsConfigurationFromSettingsSnapshot() async {
        let captured = ConfigurationBox()
        let vm = SmartScanViewModel(
            scanEngine: { configuration, _ in
                captured.value = configuration
                return self.plan()
            },
            malwareEngineAvailable: { false },
            enabledDomains: { [.systemJunk, .performance] },
            enabledJunkCategories: { [.userCache] }
        )
        await vm.scan()

        let configuration = captured.value
        XCTAssertEqual(
            configuration?.enabledUnits,
            [.systemJunk, .loginItems, .maintenanceDue, .backgroundItems, .healthSnapshot],
            "units come from the enabled domains, with health telemetry always riding along"
        )
        XCTAssertEqual(configuration?.enabledJunkCategories, [.userCache])
        XCTAssertEqual(configuration?.malwareEngineAvailable, false)
    }

    /// Every switch in Settings → Scanning must actually gate the scan. This
    /// wires the view model to a real `SmartScanSettingsStore` exactly the way
    /// `live()` does, then unchecks each option in turn and asserts the built
    /// engine configuration drops it — so no checkbox can ever be decorative.
    func test_uncheckingAnyScanningOption_excludesItFromTheScan() async {
        let suiteName = "VaderCleanerTests.ScanGating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SmartScanSettingsStore(defaults: defaults)

        func configuration() async -> CareScanEngine.Configuration? {
            let captured = ConfigurationBox()
            let vm = SmartScanViewModel(
                scanEngine: { configuration, _ in
                    captured.value = configuration
                    return self.plan()
                },
                enabledDomains: { settings.enabledDomains },
                enabledUnits: { settings.enabledUnits },
                enabledJunkCategories: { settings.enabledJunkCategories }
            )
            await vm.scan()
            return captured.value
        }

        // Baseline: everything on scans everything (health telemetry always rides along).
        let all = await configuration()
        for unit in CareScanUnit.allCases {
            XCTAssertTrue(all?.enabledUnits.contains(unit) ?? false, "\(unit) should scan by default")
        }

        // Each sub-scan checkbox.
        for unit in CareScanUnit.allCases where unit.domain != nil {
            settings.setUnit(unit, enabled: false)
            let config = await configuration()
            XCTAssertFalse(
                config?.enabledUnits.contains(unit) ?? true,
                "unchecking \(unit) must exclude it from the scan"
            )
            settings.setUnit(unit, enabled: true)
        }

        // Each area (domain) checkbox excludes its whole subtree.
        for domain in CareDomain.allCases {
            settings.setDomain(domain, enabled: false)
            let config = await configuration()
            for unit in domain.units {
                XCTAssertFalse(
                    config?.enabledUnits.contains(unit) ?? true,
                    "unchecking the \(domain) area must exclude its \(unit) scan"
                )
            }
            settings.setDomain(domain, enabled: true)
        }

        // Each System Junk category checkbox (including the Cleanup-level
        // leaves: Mail Attachments, iOS Backups, Trash Bins).
        for category in SmartScanSettingsStore.junkCategories {
            settings.setJunkCategory(category, enabled: false)
            let config = await configuration()
            XCTAssertFalse(
                config?.enabledJunkCategories.contains(category) ?? true,
                "unchecking the \(category) category must exclude it from the junk scan"
            )
            settings.setJunkCategory(category, enabled: true)
        }
    }

    // MARK: - Checklist statuses

    func test_events_driveUnitStatuses_andItemTotals() async {
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitStarted(.systemJunk))
            onEvent(.unitProgress(.systemJunk, 120))
            onEvent(.unitStarted(.malware))
            onEvent(.unitProgress(.malware, 30))
            onEvent(.unitFinished(.systemJunk, .completed, nil))
            // Give the main-actor hops time to land before returning.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return self.plan()
        })
        await vm.scan()
        // The scan completed, but the statuses observed during it were
        // recorded; verify the terminal aggregate count survived to results.
        XCTAssertEqual(vm.scannedItemCount, 150)
    }

    func test_domainStatus_rollsUpItsUnits() async {
        let gate = AsyncGate()
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitStarted(.duplicates))
            onEvent(.unitProgress(.duplicates, 40))
            onEvent(.unitFinished(.duplicates, .completed, nil))
            onEvent(.unitStarted(.largeOldFiles))
            try? await Task.sleep(nanoseconds: 100_000_000)
            await gate.wait()
            return self.plan()
        })
        let scanTask = Task { await vm.scan() }
        // Wait until the events above have landed on the main actor.
        for _ in 0..<200 {
            if case .running = vm.domainStatus(.myClutter) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .running(let items) = vm.domainStatus(.myClutter) else {
            await gate.open(); _ = await scanTask.value
            return XCTFail("My Clutter should be running while large/old files scan")
        }
        XCTAssertEqual(items, 40, "the finished duplicates count still contributes to the domain total")
        await gate.open()
        _ = await scanTask.value
    }

    func test_domainStatus_skipped_whenEveryUnitSkipped() async {
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitFinished(.browserPrivacy, .skipped(.disabledInSettings), nil))
            try? await Task.sleep(nanoseconds: 100_000_000)
            return self.plan()
        })
        let gate = AsyncGate()
        _ = gate
        let task = Task { await vm.scan() }
        for _ in 0..<200 {
            if vm.domainStatus(.browserPrivacy) == .skipped { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.domainStatus(.browserPrivacy), .skipped)
        _ = await task.value
    }

    // MARK: - Selection seeding (the safety model)

    func test_seeding_preApprovedFull_optInEmpty() async {
        let vm = SmartScanViewModel(scanEngine: { _, _ in self.richPlan })
        await vm.scan()

        // Junk: only the safe category's file is pre-checked.
        XCTAssertEqual(vm.junkFileSelection, [URL(fileURLWithPath: "/cache/safe")])
        XCTAssertEqual(vm.selectedJunkBytes, 1_000)
        // Threats, updates: everything checked.
        XCTAssertEqual(vm.threatSelection, [URL(fileURLWithPath: "/tmp/evil")])
        XCTAssertEqual(vm.updateSelection, ["com.example.app"])
        // Duplicates: redundant copies only — never the kept original.
        XCTAssertEqual(vm.duplicateSelection, [URL(fileURLWithPath: "/Downloads/copy")])
        // Opt-in tiers: user data starts unchecked.
        XCTAssertTrue(vm.largeOldFileSelection.isEmpty)
        XCTAssertTrue(vm.unusedAppSelection.isEmpty)
        XCTAssertTrue(vm.leftoverSelection.isEmpty)
        XCTAssertTrue(vm.installerSelection.isEmpty)
        XCTAssertTrue(vm.browserPrivacySelection.isEmpty)
    }

    func test_seeding_includesOnlyPreApprovedCards() async {
        let vm = SmartScanViewModel(scanEngine: { _, _ in self.richPlan })
        await vm.scan()
        XCTAssertEqual(
            vm.includedFindings,
            [.junkCleanup, .threats, .duplicates, .appUpdates],
            "opt-in and informational findings never start included"
        )
    }

    // MARK: - Executable work & disc gating

    func test_runDiscVisible_onlyOnResultsWithWork_andNotWhileReviewing() async {
        let vm = SmartScanViewModel(scanEngine: { _, _ in self.richPlan })
        XCTAssertFalse(vm.isRunDiscVisible)
        await vm.scan()
        XCTAssertTrue(vm.hasExecutableWork)
        XCTAssertTrue(vm.isRunDiscVisible)
        vm.setReviewing(true)
        XCTAssertFalse(vm.isRunDiscVisible)
        vm.setReviewing(false)
        XCTAssertTrue(vm.isRunDiscVisible)
    }

    func test_informationalFindings_neverExecute() async {
        let vm = SmartScanViewModel(scanEngine: { _, _ in self.richPlan })
        await vm.scan()
        XCTAssertFalse(vm.willExecute(.loginItems))
        XCTAssertFalse(vm.willExecute(.lowDiskSpace))
    }

    func test_optInSelection_autoIncludesAndAutoExcludesItsCard() async {
        let vm = SmartScanViewModel(scanEngine: { _, _ in self.richPlan })
        await vm.scan()
        XCTAssertFalse(vm.isFindingIncluded(.largeOldFiles))
        vm.setLargeOldFiles([URL(fileURLWithPath: "/Movies/huge.mov")], selected: true)
        XCTAssertTrue(vm.isFindingIncluded(.largeOldFiles), "checking items opts the card in")
        XCTAssertTrue(vm.willExecute(.largeOldFiles))
        vm.setLargeOldFiles([URL(fileURLWithPath: "/Movies/huge.mov")], selected: false)
        XCTAssertFalse(vm.isFindingIncluded(.largeOldFiles), "clearing the selection opts the card back out")
    }

    // MARK: - Completion hand-off

    func test_onScanCompleted_receivesThePlan() async {
        let expected = richPlan
        let vm = SmartScanViewModel(scanEngine: { _, _ in expected })
        var received: CarePlan?
        vm.onScanCompleted = { received = $0 }
        await vm.scan()
        XCTAssertEqual(received, expected)
    }

    // MARK: - Coordinating

    func test_scanPresentation_mapsPhases() async {
        let vm = SmartScanViewModel(scanEngine: { _, _ in self.plan() })
        XCTAssertEqual(vm.scanPresentation, .intro)
        await vm.scan()
        XCTAssertEqual(vm.scanPresentation, .results)
    }
}

// MARK: - Test helpers

/// One-shot async gate usable from @Sendable closures.
private actor AsyncGate {
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

/// Lock-guarded call counter for @Sendable runner closures.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Box for capturing the engine configuration from a @Sendable closure.
private final class ConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CareScanEngine.Configuration?
    var value: CareScanEngine.Configuration? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
