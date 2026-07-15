// SeededSectionScansTests.swift
// Drives the post-Smart-Scan section-scan sequencing through fake coordinators — sequential starts, idle-only gating, and completion.

import XCTest
@testable import VaderCleaner

/// Controllable stand-in for a scannable section's view model: `beginScan()`
/// flips it to `.working`, and the test finishes it by hand so the chain's
/// "wait for the previous scan" step is observable.
@MainActor
private final class FakeCoordinator: ScanCoordinating {
    private(set) var scanPresentation: ScanPresentation
    private(set) var beginScanCount = 0
    /// Called on `beginScan()` so the test can record start order.
    var onBeginScan: (() -> Void)?

    init(presentation: ScanPresentation = .intro) {
        scanPresentation = presentation
    }

    func beginScan() {
        beginScanCount += 1
        scanPresentation = .working
        onBeginScan?()
    }

    func finish() { scanPresentation = .results }
}

@MainActor
final class SeededSectionScansTests: XCTestCase {

    /// Polls (with yields) until `condition` holds, failing the test after a
    /// generous bound so a broken chain can't hang the suite.
    private func waitUntil(
        _ message: String,
        condition: () -> Bool
    ) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
        XCTFail("Timed out waiting for: \(message)")
    }

    /// The second scan must not begin until the first has left `.working` —
    /// the whole point of the chain is that the heavy seeded scans never run
    /// at the same time.
    func test_run_startsCoordinatorsSequentially() async {
        let first = FakeCoordinator()
        let second = FakeCoordinator()
        var order: [String] = []
        first.onBeginScan = { order.append("first") }
        second.onBeginScan = { order.append("second") }

        let run = Task { await SeededSectionScans.run([first, second], pollInterval: .milliseconds(1)) }
        await waitUntil("first scan to start") { first.beginScanCount == 1 }
        XCTAssertEqual(second.beginScanCount, 0, "The second scan must wait for the first to finish")

        first.finish()
        await waitUntil("second scan to start") { second.beginScanCount == 1 }
        second.finish()
        await run.value

        XCTAssertEqual(order, ["first", "second"])
    }

    /// A section that is no longer on its intro — the user scanned it
    /// themselves, or a previous seed already populated it — is left alone.
    func test_run_skipsCoordinatorsThatAreNotIdle() async {
        let alreadyScanned = FakeCoordinator(presentation: .results)
        let alreadyWorking = FakeCoordinator(presentation: .working)
        alreadyWorking.finish() // ends `.working` so the chain never waits on it
        let idle = FakeCoordinator()

        await SeededSectionScans.run(
            [alreadyScanned, alreadyWorking, idle],
            pollInterval: .milliseconds(1)
        )

        XCTAssertEqual(alreadyScanned.beginScanCount, 0)
        XCTAssertEqual(alreadyWorking.beginScanCount, 0)
        XCTAssertEqual(idle.beginScanCount, 1, "Idle sections still get their seeded scan")
    }

    /// An empty chain completes immediately — the degenerate case must not hang.
    func test_run_withNoCoordinators_returns() async {
        await SeededSectionScans.run([], pollInterval: .milliseconds(1))
    }
}
