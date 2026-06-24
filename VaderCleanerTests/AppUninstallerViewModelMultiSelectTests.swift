// AppUninstallerViewModelMultiSelectTests.swift
// Tests the AppUninstallerViewModel multi-select batch uninstall used by the Applications Manager — selection toggling and the best-effort removal of every checked app and its associated files through injected fakes.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUninstallerViewModelMultiSelectTests: XCTestCase {

    // MARK: - Selection

    /// Toggling adds then removes an id from the uninstall selection.
    func test_toggleUninstallSelection_addsThenRemoves() {
        let vm = makeViewModel()
        vm.toggleUninstallSelection("a")
        XCTAssertTrue(vm.isInUninstallSelection("a"))
        vm.toggleUninstallSelection("a")
        XCTAssertFalse(vm.isInUninstallSelection("a"))
    }

    /// Select-all fills the selection from the supplied ids; clear empties it.
    func test_selectAllThenClear() {
        let vm = makeViewModel()
        vm.selectAllForUninstall(["a", "b", "c"])
        XCTAssertEqual(vm.uninstallSelection, ["a", "b", "c"])
        vm.clearUninstallSelection()
        XCTAssertTrue(vm.uninstallSelection.isEmpty)
    }

    /// The footer's action is gated on a non-empty selection.
    func test_canUninstallSelection_requiresSelection() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.canUninstallSelection)
        vm.toggleUninstallSelection("a")
        XCTAssertTrue(vm.canUninstallSelection)
    }

    // MARK: - Batch uninstall

    /// `uninstallSelected()` recycles each selected app's bundle + associated
    /// files, drops them from the list, clears their selection, and lands in
    /// `.complete` with the summed bytes freed.
    func test_uninstallSelected_removesEverySelectedApp() async {
        let a = makeApp(name: "Alpha", bundleID: "com.test.alpha")
        let b = makeApp(name: "Bravo", bundleID: "com.test.bravo")
        let c = makeApp(name: "Charlie", bundleID: "com.test.charlie")

        let recycledBundles = Box<[URL]>([])
        let vm = makeViewModel(
            discover: { _ in [a, b, c] },
            findFiles: { _ in [] },
            recycle: { bundleURL, _ in
                recycledBundles.value.append(bundleURL)
                return AppUninstallerViewModel.RecycleOutcome(bytesFreed: 10, bundlePermanentlyRemoved: false)
            }
        )
        await vm.loadApps()
        vm.selectAllForUninstall([a.id, c.id])

        await vm.uninstallSelected()

        XCTAssertEqual(vm.phase, .complete(bytesFreed: 20, permanentRemoval: false))
        XCTAssertEqual(Set(vm.apps.map(\.id)), [b.id])
        XCTAssertTrue(vm.uninstallSelection.isEmpty)
        XCTAssertEqual(Set(recycledBundles.value), [a.bundleURL, c.bundleURL])
    }

    /// A per-app failure is tolerated: the others are still removed and the
    /// flow completes (best-effort), keeping the failed app in the list.
    func test_uninstallSelected_isBestEffortOnPartialFailure() async {
        let a = makeApp(name: "Alpha", bundleID: "com.test.alpha")
        let b = makeApp(name: "Bravo", bundleID: "com.test.bravo")

        let vm = makeViewModel(
            discover: { _ in [a, b] },
            findFiles: { _ in [] },
            recycle: { bundleURL, _ in
                if bundleURL == a.bundleURL { throw BatchBoom() }
                return AppUninstallerViewModel.RecycleOutcome(bytesFreed: 7, bundlePermanentlyRemoved: false)
            }
        )
        await vm.loadApps()
        vm.selectAllForUninstall([a.id, b.id])

        await vm.uninstallSelected()

        XCTAssertEqual(vm.phase, .complete(bytesFreed: 7, permanentRemoval: false))
        XCTAssertEqual(vm.apps.map(\.id), [a.id])          // the failed app stays
        XCTAssertEqual(vm.uninstallSelection, [a.id])       // and stays selected
    }

    /// When every selected app fails, the flow lands in `.failed` rather than a
    /// false "Complete".
    func test_uninstallSelected_failsWhenNothingRemoved() async {
        let a = makeApp(name: "Alpha", bundleID: "com.test.alpha")
        let vm = makeViewModel(
            discover: { _ in [a] },
            findFiles: { _ in [] },
            recycle: { _, _ in throw BatchBoom() }
        )
        await vm.loadApps()
        vm.selectAllForUninstall([a.id])

        await vm.uninstallSelected()

        guard case .failed(let stage, _, _) = vm.phase else {
            return XCTFail("expected .failed, got \(vm.phase)")
        }
        XCTAssertEqual(stage, .uninstalling)
        XCTAssertEqual(vm.apps.map(\.id), [a.id])
    }

    // MARK: - Helpers

    private func makeViewModel(
        discover: @escaping AppUninstallerViewModel.Discover = { _ in [] },
        findFiles: @escaping AppUninstallerViewModel.FindFiles = { _ in [] },
        recycle: @escaping AppUninstallerViewModel.Recycle = { _, _ in
            AppUninstallerViewModel.RecycleOutcome(bytesFreed: 0, bundlePermanentlyRemoved: false)
        }
    ) -> AppUninstallerViewModel {
        AppUninstallerViewModel(discover: discover, findFiles: findFiles, recycle: recycle)
    }

    private func makeApp(name: String, bundleID: String) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: false
        )
    }
}

/// Minimal mutable reference box so an injected `@Sendable` recycle closure can
/// record what it was asked to remove.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ initial: Value) { value = initial }
}

private struct BatchBoom: Error {}
