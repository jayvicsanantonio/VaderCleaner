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
        XCTAssertTrue(vm.checkedCategories.isEmpty)
        XCTAssertEqual(vm.totalSelectedSize, 0)
    }

    // MARK: - Scan transitions

    /// `scan()` must advance through `.scanning` and land on `.preview` once
    /// the injected scanner closure resolves. We capture every emitted phase
    /// from `$phase.sink` to assert the transient `.scanning` value really
    /// appeared — without that subscription the test could pass even if the
    /// VM jumped straight from `.idle` to `.preview`.
    func test_scan_transitionsIdleToScanningToPreview() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)]),
            (.userLogs,  [makeFile(name: "b", size: 200, category: .userLogs)])
        )
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)

        var phases: [SystemJunkViewModel.Phase] = []
        let cancellable = vm.$phase.sink { phases.append($0) }

        await vm.scan()
        cancellable.cancel()

        XCTAssertEqual(phases.first, .idle, "Expected initial .idle to be replayed by sink")
        XCTAssertTrue(phases.contains(.scanning), "Expected to observe .scanning during scan()")
        XCTAssertEqual(phases.last, .preview(result))
    }

    /// All categories present in the scan result must be checked by default —
    /// the user opts out of categories rather than opting in, matching the
    /// expectation set in the plan and how cleaner UIs typically work.
    func test_scan_marksEveryCategoryCheckedByDefault() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)]),
            (.systemLogs, [makeFile(name: "b", size: 200, category: .systemLogs)]),
            (.trash, [makeFile(name: "c", size: 300, category: .trash)])
        )
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)

        await vm.scan()

        XCTAssertEqual(vm.checkedCategories, [.userCache, .systemLogs, .trash])
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

    /// Toggling a category off must drop both the membership and its bytes
    /// from `totalSelectedSize`. Toggling it back on must restore the total —
    /// the selection state is purely additive, with no side-effects on the
    /// underlying scan result.
    func test_toggle_updatesCheckedCategoriesAndTotalSelectedSize() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)]),
            (.userLogs,  [makeFile(name: "b", size: 250, category: .userLogs)])
        )
        let vm = makeViewModel(scanner: { result }, deleter: noopDeleter)
        await vm.scan()
        XCTAssertEqual(vm.totalSelectedSize, 350)

        vm.toggle(.userCache)
        XCTAssertFalse(vm.checkedCategories.contains(.userCache))
        XCTAssertEqual(vm.totalSelectedSize, 250)

        vm.toggle(.userCache)
        XCTAssertTrue(vm.checkedCategories.contains(.userCache))
        XCTAssertEqual(vm.totalSelectedSize, 350)
    }

    // MARK: - Clean

    /// `clean()` must hand the deleter only the files whose category is
    /// currently checked. An unchecked category's files must not be passed
    /// through — we cannot rely on the deleter to filter, the view-model owns
    /// the contract.
    func test_clean_invokesDeleterOnlyForCheckedCategories() async {
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
        vm.toggle(.userLogs)  // uncheck user logs
        await vm.clean()

        let received = await recorded.value
        XCTAssertEqual(received, [userFile], "Deleter must receive only files in checked categories")
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

    /// `clean()` is a no-op when nothing is checked — the View disables the
    /// button in this state, but the VM contract must hold even if a hot-key
    /// path or future caller bypasses the disabled state.
    func test_clean_withNoSelectionDoesNotInvokeDeleter() async {
        let result = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)])
        )
        let invoked = ActorBox(false)
        let vm = makeViewModel(
            scanner: { result },
            deleter: { _ in
                await invoked.set(true)
                return 0
            }
        )

        await vm.scan()
        vm.toggle(.userCache)  // now nothing is checked
        await vm.clean()

        let didInvoke = await invoked.value
        XCTAssertFalse(didInvoke, "Deleter must not be called when no category is checked")
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
        XCTAssertTrue(vm.checkedCategories.isEmpty)
    }

    // MARK: - Helpers

    private func makeViewModel(
        scanner: @escaping () async throws -> ScanResult = { ScanResult(items: []) },
        deleter: @escaping ([ScannedFile]) async throws -> Int64 = { _ in 0 }
    ) -> SystemJunkViewModel {
        SystemJunkViewModel(scanner: scanner, deleter: deleter)
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
