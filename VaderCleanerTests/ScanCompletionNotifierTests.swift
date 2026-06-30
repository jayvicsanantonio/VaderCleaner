// ScanCompletionNotifierTests.swift
// Verifies a "scan complete" notification fires only for armed (user-initiated) scans that reach results.

import XCTest
@testable import VaderCleaner

/// Minimal `ScanCoordinating` whose presentation the test drives directly.
@MainActor
@Observable
private final class FakeScanCoordinator: ScanCoordinating {
    var scanPresentation: ScanPresentation
    init(_ presentation: ScanPresentation = .intro) { scanPresentation = presentation }
    func beginScan() { scanPresentation = .working }
}

/// A coordinator that, like the Protection dashboard, sits at `.results` while
/// still scanning and reports real completion separately.
@MainActor
@Observable
private final class FakeReportingCoordinator: ScanCoordinating, ScanCompletionReporting {
    var scanPresentation: ScanPresentation = .results
    var isScanComplete: Bool = false
    func beginScan() { isScanComplete = false }
}

@MainActor
final class ScanCompletionNotifierTests: XCTestCase {

    private var preferences: PreferencesStore!
    private var dispatcher: StubNotificationDispatcher!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.ScanCompletion.\(UUID().uuidString)")!
        preferences = PreferencesStore(defaults: defaults)
        dispatcher = StubNotificationDispatcher()
    }

    private func makeNotifier() -> ScanCompletionNotifier {
        ScanCompletionNotifier(preferences: preferences, dispatcher: dispatcher)
    }

    func test_fires_whenArmedScanReachesResults() {
        preferences.notifyScanFinished = true
        let coordinator = FakeScanCoordinator(.working)
        let notifier = makeNotifier()

        notifier.armScan(section: .systemJunk, coordinator: coordinator)
        coordinator.scanPresentation = .results
        notifier.evaluate(section: .systemJunk)

        XCTAssertEqual(dispatcher.calls, [.scanFinished(scanName: NavigationSection.systemJunk.title)])
    }

    func test_doesNotFire_whenNotArmed() {
        preferences.notifyScanFinished = true
        let notifier = makeNotifier()

        notifier.evaluate(section: .applications)

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_doesNotArm_whenToggleOff() {
        preferences.notifyScanFinished = false
        let coordinator = FakeScanCoordinator(.working)
        let notifier = makeNotifier()

        notifier.armScan(section: .applications, coordinator: coordinator)
        coordinator.scanPresentation = .results
        notifier.evaluate(section: .applications)

        XCTAssertTrue(dispatcher.calls.isEmpty)
    }

    func test_firesOnce_perScan() {
        preferences.notifyScanFinished = true
        let coordinator = FakeScanCoordinator(.working)
        let notifier = makeNotifier()

        notifier.armScan(section: .performance, coordinator: coordinator)
        coordinator.scanPresentation = .results
        notifier.evaluate(section: .performance)
        notifier.evaluate(section: .performance)   // already disarmed

        XCTAssertEqual(dispatcher.calls.count, 1)
    }

    // MARK: - Completion-reporting coordinators (e.g. Protection)

    func test_reportingCoordinator_doesNotFireWhileScanIncompleteEvenAtResults() {
        preferences.notifyScanFinished = true
        let coordinator = FakeReportingCoordinator()   // .results but isScanComplete == false
        let notifier = makeNotifier()

        notifier.armScan(section: .malwareRemoval, coordinator: coordinator)
        notifier.evaluate(section: .malwareRemoval)

        XCTAssertTrue(dispatcher.calls.isEmpty,
                      "A live dashboard sitting at .results must not notify until its scan actually completes")
    }

    func test_reportingCoordinator_firesWhenScanCompletes() {
        preferences.notifyScanFinished = true
        let coordinator = FakeReportingCoordinator()
        let notifier = makeNotifier()

        notifier.armScan(section: .malwareRemoval, coordinator: coordinator)
        coordinator.isScanComplete = true
        notifier.evaluate(section: .malwareRemoval)

        XCTAssertEqual(dispatcher.calls, [.scanFinished(scanName: NavigationSection.malwareRemoval.title)])
    }

    func test_disarms_whenScanReturnsToIntro() {
        preferences.notifyScanFinished = true
        let coordinator = FakeScanCoordinator(.working)
        let notifier = makeNotifier()

        notifier.armScan(section: .spaceLens, coordinator: coordinator)
        coordinator.scanPresentation = .intro       // started over / cancelled
        notifier.evaluate(section: .spaceLens)
        coordinator.scanPresentation = .results
        notifier.evaluate(section: .spaceLens)

        XCTAssertTrue(dispatcher.calls.isEmpty, "A cancelled scan must not notify on a later result")
    }
}
