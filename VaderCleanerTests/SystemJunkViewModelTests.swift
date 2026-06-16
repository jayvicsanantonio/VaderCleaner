// SystemJunkViewModelTests.swift
// Tests the SystemJunkViewModel state machine, selection logic, and clean dispatch — driving each transition (idle → scanning → preview → cleaning → complete) through injected fake scanner and deleter closures so no real filesystem or XPC helper is touched.

import XCTest
import Combine
@testable import VaderCleaner

@MainActor
final class SystemJunkViewModelTests: XCTestCase {

    // MARK: - Initial state

    /// The view-model must arrive in `.idle` so the System Junk view renders
    /// its "Scan" CTA on first appearance, not a momentary preview/cleaning
    /// flash from a stale cached state.
    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.selectedURLs.isEmpty)
        XCTAssertEqual(vm.totalSelectedSize, 0)
    }

    // MARK: - Scan transitions

    /// `scan()` must advance through `.scanning` and land on `.preview` once
    /// the injected scanner closure resolves. We assert the transient
    /// `.scanning` value with a continuation-gated scanner — once the gate
    /// suspends the scan, the test reads `phase` directly. Without that
    /// gate the test would silently pass even if the VM jumped straight
    /// from `.idle` to `.preview`. The post-gate assertion confirms the
    /// terminal phase is `.preview(result)`. Same pattern
    /// `ScanCoordinatingConformanceTests` uses to pin `.scanning`.
    func test_scan_transitionsIdleToScanningToPreview() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)]),
            (.userLogs,  [makeFile(name: "b", size: 200, category: .userLogs)])
        )
        let gate = ScanPhaseGate()
        let vm = makeViewModel(
            scanner: {
                await gate.wait()
                return result
            },
            deleter: noopDeleter
        )

        XCTAssertEqual(vm.phase, .idle, "Expected initial phase to be .idle")

        let task = Task { await vm.scan() }
        await yieldUntil({ vm.phase == .scanning }, "scan() advanced to .scanning")
        XCTAssertEqual(vm.phase, .scanning)

        await gate.open()
        await task.value
        XCTAssertEqual(vm.phase, .preview(result))
    }

    /// Single-shot continuation gate so the test can freeze `scan()` mid-flight
    /// to observe `.scanning`, then resume to observe `.preview`. Mirrors
    /// `ScanCoordinatingConformanceTests.ScanGate`; lives here so this file
    /// stays self-contained.
    @MainActor
    private final class ScanPhaseGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func yieldUntil(
        _ predicate: () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for: \(message)", file: file, line: line)
    }

    /// Every file in the scan result must be selected by default — the user
    /// opts out of files rather than opting in, matching how cleaner UIs treat
    /// safe-to-remove junk (and the section's prior "all categories checked"
    /// behaviour, now expressed per file).
    func test_scan_selectsEveryFileByDefault() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 200, category: .systemLogs)
        let c = makeFile(name: "c", size: 300, category: .trash)
        let result = makeResult(
            (.userCache, [a]),
            (.systemLogs, [b]),
            (.trash, [c])
        )
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)

        await vm.scan()

        XCTAssertEqual(vm.selectedURLs, [a.url, b.url, c.url])
        XCTAssertEqual(vm.totalSelectedSize, 600)
    }

    /// A scanner that throws must surface a `.failed` phase rather than leave
    /// the view-model stuck in `.scanning` — otherwise the spinner would never
    /// resolve and the user has no way back.
    func test_scan_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let vm = makeViewModel(
            scanner: { throw BoomError() },
            deleter: noopDeleter
        )

        await vm.scan()

        if case .failed = vm.phase {
            // expected
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    // MARK: - Selection

    /// Toggling a file off must drop both its URL and its bytes from
    /// `totalSelectedSize`. Toggling it back on must restore the total — the
    /// selection state is purely additive, with no side-effects on the
    /// underlying scan result.
    func test_toggleSelection_updatesSelectedURLsAndTotalSelectedSize() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 250, category: .userLogs)
        let result = makeResult(
            (.userCache, [a]),
            (.userLogs,  [b])
        )
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        XCTAssertEqual(vm.totalSelectedSize, 350)

        vm.toggleSelection(a)
        XCTAssertFalse(vm.selectedURLs.contains(a.url))
        XCTAssertEqual(vm.totalSelectedSize, 250)

        vm.toggleSelection(a)
        XCTAssertTrue(vm.selectedURLs.contains(a.url))
        XCTAssertEqual(vm.totalSelectedSize, 350)
    }

    // MARK: - Clean

    /// `clean()` must hand the deleter only the files that are currently
    /// selected. A deselected file must not be passed through — we cannot rely
    /// on the deleter to filter, the view-model owns the contract.
    func test_clean_invokesDeleterOnlyForSelectedFiles() async {
        let userFile = makeFile(name: "a", size: 100, category: .userCache)
        let logFile  = makeFile(name: "b", size: 250, category: .userLogs)
        let result = makeResult(
            (.userCache, [userFile]),
            (.userLogs,  [logFile])
        )
        let recorded = ActorBox<[ScannedFile]>([])
        let vm = makeViewModel(
            scanner: { result },
            deleter: { files in
                await recorded.set(files)
                return files.reduce(Int64(0)) { $0 + $1.size }
            }
        )

        await vm.scan()
        vm.toggleSelection(logFile)  // deselect the log file
        await vm.clean()

        let received = await recorded.value
        XCTAssertEqual(received, [userFile], "Deleter must receive only selected files")
    }

    /// After a successful clean, the phase becomes `.complete(bytesFreed)` so
    /// the view can render the success summary and offer "Scan Again". Bytes
    /// freed comes from the deleter so partial-failure cases (helper deletes
    /// 9 of 10 files) report accurate values rather than the full selection.
    func test_clean_transitionsToCompleteWithBytesFreed() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 1_024, category: .userCache)])
        )
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in 1_024 }
        )

        await vm.scan()
        await vm.clean()

        XCTAssertEqual(vm.phase, .complete(bytesFreed: 1_024))
    }

    /// A throwing deleter must surface `.failed` rather than leaving the user
    /// stuck on the cleaning spinner. We don't claim "X bytes freed" if the
    /// underlying delete blew up — better to show an error and let the user
    /// retry.
    func test_clean_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)])
        )
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in throw BoomError() }
        )

        await vm.scan()
        await vm.clean()

        if case .failed = vm.phase {
            // expected
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    /// `clean()` is a no-op when nothing is selected — the View disables the
    /// button in this state, but the VM contract must hold even if a hot-key
    /// path or future caller bypasses the disabled state.
    func test_clean_withNoSelectionDoesNotInvokeDeleter() async {
        let file = makeFile(name: "a", size: 100, category: .userCache)
        let result = makeResult((.userCache, [file]))
        let invoked = ActorBox(false)
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in
                await invoked.set(true)
                return 0
            }
        )

        await vm.scan()
        vm.toggleSelection(file)  // now nothing is selected
        await vm.clean()

        let didInvoke = await invoked.value
        XCTAssertFalse(didInvoke, "Deleter must not be called when no file is selected")
    }

    // MARK: - Scan again

    /// `scanAgain()` returns the view-model to `.idle` so the user is back at
    /// the Scan CTA — selection state is dropped because the previous result
    /// is no longer valid.
    func test_scanAgain_returnsToIdle() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)])
        )
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in 100 }
        )
        await vm.scan()
        await vm.clean()
        XCTAssertEqual(vm.phase, .complete(bytesFreed: 100))

        vm.scanAgain()

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.selectedURLs.isEmpty)
    }

    // MARK: - Scan progress count

    /// The scanner's progress callback must drive `scannedItemCount` so the
    /// scanning screen can show the walk advancing.
    func test_scan_reportsScannedItemCountFromProgress() async {
        let vm = SystemJunkViewModel(
            scanner: { progress in
                progress(64)
                await Task.yield()
                progress(900)
                await Task.yield()
                return ScanResult(items: [])
            },
            deleter: { _ in 0 }
        )

        await vm.scan()
        await waitUntil { vm.scannedItemCount == 900 }

        XCTAssertEqual(vm.scannedItemCount, 900)
    }

    /// Each scan must restart the counter from zero rather than carry the
    /// previous run's total forward.
    func test_scan_restartsScannedItemCountEachScan() async {
        let vm = SystemJunkViewModel(
            scanner: { progress in
                progress(900)
                await Task.yield()
                return ScanResult(items: [])
            },
            deleter: { _ in 0 }
        )

        await vm.scan()
        await waitUntil { vm.scannedItemCount == 900 }

        let observed = await recordTransitions(of: \.scannedItemCount, on: vm) {
            await vm.scan()
            await waitUntil { vm.scannedItemCount == 900 }
        }

        XCTAssertTrue(
            observed.contains(0),
            "A new scan must reset the counter to zero before counting up again, got \(observed)"
        )
    }

    // MARK: - Helpers

    private func makeViewModel(
        scanner: @escaping () async throws -> ScanResult = { ScanResult(items: []) },
        deleter: @escaping ([ScannedFile]) async throws -> Int64 = { _ in 0 }
    ) -> SystemJunkViewModel {
        // Adapt the progress-free test closures to the production scanner
        // signature; the count test constructs the VM directly to drive the
        // progress callback.
        SystemJunkViewModel(scanner: { _ in try await scanner() }, deleter: deleter)
    }

    private func makeResult(_ groups: (ScanCategory, [ScannedFile])...) -> ScanResult {
        let items = groups.flatMap { $0.1 }
        return ScanResult(items: items)
    }

    private func makeFile(name: String, size: Int64, category: ScanCategory) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/sjv-tests/\(category.rawValue)/\(name)"),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    /// Default no-op deleter for tests that don't exercise the clean path.
    private let noopDeleter: ([ScannedFile]) async throws -> Int64 = { _ in 0 }
}

/// Small actor wrapper that lets test deleter closures record values without
/// data-race warnings under Swift's strict concurrency checks. The deleter
/// closure is `@Sendable`, so it cannot capture a `@MainActor` test fixture's
/// stored properties directly — funnelling values through an actor is the
/// simplest race-free alternative.
private actor ActorBox<Value: Sendable> {
    private(set) var value: Value
    init(_ initial: Value) { self.value = initial }
    func set(_ newValue: Value) { value = newValue }
}
