// AppUninstallerViewModelTests.swift
// Tests the AppUninstallerViewModel state machine — load, selection, associated files lookup, total reclaimable, uninstall, failure paths — driving every transition through injected fakes so no real apps are touched.

import XCTest
@testable import VaderCleaner

@MainActor
final class AppUninstallerViewModelTests: XCTestCase {

    // MARK: - Initial state

    /// On construction the VM is `.idle` so the view shows its loading state
    /// after `task { loadApps() }` rather than a stale list from a prior
    /// session.
    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.apps.isEmpty)
        XCTAssertNil(vm.selectedAppID)
    }

    // MARK: - Load

    /// `loadApps()` populates the app list and lands in `.ready`.
    func test_loadApps_transitionsToReadyWithSortedApps() async {
        let apps = [
            makeApp(name: "Zephyr", bundleID: "com.acme.zephyr"),
            makeApp(name: "Alpha", bundleID: "com.acme.alpha")
        ]
        let vm = makeViewModel(
            discover: { _ in apps }
        )
        await vm.loadApps()
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(vm.apps.map(\.bundleID), ["com.acme.zephyr", "com.acme.alpha"])
    }

    /// A throwing discovery surfaces `.failed(stage: .loading, ...)`.
    func test_loadApps_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let vm = makeViewModel(discover: { _ in throw BoomError() })
        await vm.loadApps()

        if case .failed(let stage, _) = vm.phase {
            XCTAssertEqual(stage, .loading)
        } else {
            XCTFail("Expected .failed(.loading), got \(vm.phase)")
        }
        XCTAssertTrue(vm.apps.isEmpty)
    }

    /// Toggling `includesSystemApps` and reloading must forward the flag
    /// to the discovery layer.
    func test_reloadApps_forwardsIncludesSystemAppsFlag() async {
        var receivedFlag: Bool?
        let vm = makeViewModel(discover: { includes in
            receivedFlag = includes
            return []
        })
        vm.includesSystemApps = true
        await vm.reloadApps()
        XCTAssertEqual(receivedFlag, true)
    }

    // MARK: - Filtering

    /// `filteredApps` matches case-insensitively on name and bundle ID.
    func test_filteredApps_matchesNameAndBundleID() async {
        let apps = [
            makeApp(name: "Helio", bundleID: "com.acme.helio"),
            makeApp(name: "Mango", bundleID: "com.acme.mango"),
            makeApp(name: "Solar", bundleID: "com.unrelated.solar")
        ]
        let vm = makeViewModel(discover: { _ in apps })
        await vm.loadApps()

        vm.searchQuery = "helio"
        XCTAssertEqual(vm.filteredApps.map(\.bundleID), ["com.acme.helio"])

        vm.searchQuery = "ACME"
        XCTAssertEqual(vm.filteredApps.map(\.bundleID).sorted(),
                       ["com.acme.helio", "com.acme.mango"])

        vm.searchQuery = ""
        XCTAssertEqual(vm.filteredApps.count, 3)
    }

    // MARK: - Selection

    /// Selecting an app populates `associatedFiles` from the injected finder.
    func test_select_populatesAssociatedFiles() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let stubFiles = [
            AssociatedFile(
                url: URL(fileURLWithPath: "/tmp/p.plist"),
                sizeBytes: 10,
                category: .preferences
            ),
            AssociatedFile(
                url: URL(fileURLWithPath: "/tmp/c.bin"),
                sizeBytes: 50,
                category: .cache
            )
        ]
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in stubFiles }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { vm.associatedFiles.count == stubFiles.count }
        XCTAssertEqual(vm.associatedFiles.map(\.sizeBytes), [10, 50])
        XCTAssertFalse(vm.isLoadingAssociatedFiles)
    }

    /// Deselecting (passing `nil`) clears the associated files panel.
    func test_select_nilClearsAssociatedFiles() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [
                AssociatedFile(url: URL(fileURLWithPath: "/tmp/p"), sizeBytes: 1, category: .preferences)
            ] }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { !vm.associatedFiles.isEmpty }
        vm.select(nil)
        XCTAssertNil(vm.selectedAppID)
        XCTAssertTrue(vm.associatedFiles.isEmpty)
    }

    /// Re-selecting the same app reuses the cached associated files and
    /// does not invoke the finder again.
    func test_select_secondTimeUsesCache() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        var finderCalls = 0
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in
                finderCalls += 1
                return [AssociatedFile(url: URL(fileURLWithPath: "/tmp/p"), sizeBytes: 1, category: .preferences)]
            }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { !vm.associatedFiles.isEmpty }
        vm.select(nil)
        vm.select(app.id)
        await waitFor { !vm.associatedFiles.isEmpty }
        XCTAssertEqual(finderCalls, 1)
    }

    // MARK: - Totals

    /// `totalReclaimableSize` is bundle size + sum of associated files
    /// once both async lookups have landed.
    func test_totalReclaimableSize_isBundleSizePlusAssociated() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let stubFiles = [
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/a"), sizeBytes: 50, category: .cache),
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/b"), sizeBytes: 200, category: .logs)
        ]
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in stubFiles },
            measureSize: { _ in 1_000 }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { !vm.associatedFiles.isEmpty && vm.selectedAppBundleSize != nil }
        XCTAssertEqual(vm.totalReclaimableSize, 1_250)
    }

    /// `bundleSize(for:)` returns `nil` until the per-app size
    /// measurement lands, then the measured value. The list row uses
    /// this to defer rendering the size label.
    func test_bundleSize_returnsNilUntilMeasured() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [] },
            measureSize: { _ in 4_096 }
        )
        await vm.loadApps()
        XCTAssertNil(vm.bundleSize(for: app.id),
                     "Bundle size must not be computed during discovery")
        vm.select(app.id)
        await waitFor { vm.bundleSize(for: app.id) != nil }
        XCTAssertEqual(vm.bundleSize(for: app.id), 4_096)
    }

    /// `canUninstallSelectedApp` is false while the associated-files
    /// scan is in flight so the destructive button is disabled — see
    /// the Codex review comment on the uninstall flow.
    func test_canUninstallSelectedApp_isFalseWhileAssociatedFilesLoading() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let releaseFinder = ActorBox<CheckedContinuation<Void, Never>?>(nil)
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in
                await withCheckedContinuation { continuation in
                    Task { await releaseFinder.set(continuation) }
                }
                return []
            }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitForActor { await releaseFinder.value != nil }
        XCTAssertTrue(vm.isLoadingAssociatedFiles)
        XCTAssertFalse(vm.canUninstallSelectedApp,
                       "Uninstall must be gated while associated files are still being scanned")

        // Release the finder and confirm canUninstall flips true.
        let continuation: CheckedContinuation<Void, Never>? = await releaseFinder.value
        continuation?.resume()
        await waitFor { !vm.isLoadingAssociatedFiles }
        XCTAssertTrue(vm.canUninstallSelectedApp)
    }

    /// `uninstall()` must be a no-op while the associated-files scan is
    /// in flight — confirming early would otherwise Trash only the
    /// bundle and leave caches/preferences behind.
    func test_uninstall_isNoOpWhileAssociatedFilesLoading() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let recycleCalls = ActorBox(0)
        let releaseFinder = ActorBox<CheckedContinuation<Void, Never>?>(nil)
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in
                await withCheckedContinuation { continuation in
                    Task { await releaseFinder.set(continuation) }
                }
                return []
            },
            recycle: { _, _ in await recycleCalls.increment(); return 1 }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitForActor { await releaseFinder.value != nil }
        XCTAssertTrue(vm.isLoadingAssociatedFiles)
        await vm.uninstall()
        let count = await recycleCalls.value
        XCTAssertEqual(count, 0, "uninstall must not run while scan is in flight")
        let continuation: CheckedContinuation<Void, Never>? = await releaseFinder.value
        continuation?.resume()
    }

    /// Files are exposed grouped by category in declaration order.
    func test_associatedFilesByCategory_groupsAndSortsByDeclarationOrder() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let stubFiles = [
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/a"), sizeBytes: 1, category: .logs),
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/b"), sizeBytes: 1, category: .preferences),
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/c"), sizeBytes: 1, category: .cache)
        ]
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in stubFiles }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { !vm.associatedFiles.isEmpty }
        let groups = vm.associatedFilesByCategory
        XCTAssertEqual(groups.map(\.0), [.preferences, .cache, .logs])
    }

    // MARK: - Uninstall

    /// `uninstall()` hands the bundle URL + every associated URL to the
    /// recycler, drops the app from `apps`, and lands in `.complete`.
    func test_uninstall_invokesRecyclerWithBundleAndAssociatedURLs() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let stubFiles = [
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/p"), sizeBytes: 10, category: .preferences),
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/c"), sizeBytes: 50, category: .cache)
        ]
        let receivedBundle = ActorBox<URL?>(nil)
        let receivedAssociated = ActorBox<[URL]>([])
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in stubFiles },
            recycle: { bundleURL, associatedURLs in
                await receivedBundle.set(bundleURL)
                await receivedAssociated.set(associatedURLs)
                return 60
            }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { !vm.associatedFiles.isEmpty }

        await vm.uninstall()

        let bundle = await receivedBundle.value
        let associated = await receivedAssociated.value
        XCTAssertEqual(bundle, app.bundleURL)
        XCTAssertEqual(Set(associated), Set(stubFiles.map(\.url)))
        XCTAssertEqual(vm.phase, .complete(bytesFreed: 60))
        XCTAssertFalse(vm.apps.contains(where: { $0.id == app.id }))
        XCTAssertNil(vm.selectedAppID)
    }

    /// If the recycler reports that the bundle could not be moved
    /// (e.g. root-owned `/Applications/*.app` denied while user-domain
    /// associated files succeeded), the view-model must surface
    /// `.failed(.uninstalling)` rather than showing "complete" — the
    /// app is still installed, leaving a stale row in the list would
    /// mislead the user. Codex P2 on PR #58.
    func test_uninstall_recyclerBundleFailureSurfacesAsFailed() async {
        struct BundleNotMovedError: Error {}
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [] },
            recycle: { _, _ in throw BundleNotMovedError() }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { vm.canUninstallSelectedApp }
        await vm.uninstall()

        if case .failed(let stage, _) = vm.phase {
            XCTAssertEqual(stage, .uninstalling)
        } else {
            XCTFail("Expected .failed(.uninstalling), got \(vm.phase)")
        }
        // App row must still be present so the user can retry.
        XCTAssertTrue(vm.apps.contains(where: { $0.id == app.id }),
                      "App must stay in the list when its bundle was not Trashed")
    }

    /// A throwing recycler surfaces `.failed(stage: .uninstalling, ...)`.
    func test_uninstall_failureTransitionsToFailed() async {
        struct BoomError: Error {}
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [] },
            recycle: { _, _ in throw BoomError() }
        )
        await vm.loadApps()
        vm.select(app.id)
        // Wait for the associated-files scan to finish — `uninstall()`
        // is a no-op while the scan is still in flight, so an early call
        // would never reach the recycler.
        await waitFor { vm.canUninstallSelectedApp }
        await vm.uninstall()
        if case .failed(let stage, _) = vm.phase {
            XCTAssertEqual(stage, .uninstalling)
        } else {
            XCTFail("Expected .failed(.uninstalling), got \(vm.phase)")
        }
    }

    /// `uninstall()` is a no-op when nothing is selected.
    func test_uninstall_isNoOpWithoutSelection() async {
        let calls = ActorBox(0)
        let vm = makeViewModel(
            discover: { _ in [] },
            recycle: { _, _ in await calls.increment(); return 0 }
        )
        await vm.loadApps()
        await vm.uninstall()
        let count = await calls.value
        XCTAssertEqual(count, 0)
        XCTAssertEqual(vm.phase, .ready)
    }

    /// `dismissResult()` brings the VM back to `.ready` after a complete
    /// or failed phase.
    func test_dismissResult_returnsToReady() async {
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [] },
            recycle: { _, _ in 0 }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { vm.canUninstallSelectedApp }
        await vm.uninstall()
        vm.dismissResult()
        XCTAssertEqual(vm.phase, .ready)
    }

    // MARK: - Helpers

    private func makeViewModel(
        discover: @escaping AppUninstallerViewModel.Discover = { _ in [] },
        findFiles: @escaping AppUninstallerViewModel.FindFiles = { _ in [] },
        measureSize: @escaping AppUninstallerViewModel.MeasureSize = { _ in 0 },
        recycle: @escaping AppUninstallerViewModel.Recycle = { _, _ in 0 }
    ) -> AppUninstallerViewModel {
        AppUninstallerViewModel(
            discover: discover,
            findFiles: findFiles,
            measureSize: measureSize,
            recycle: recycle
        )
    }

    private func makeApp(
        name: String,
        bundleID: String
    ) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: false
        )
    }

    /// Polls `condition` on the main actor until it becomes true or the
    /// timeout elapses. Used because `select(...)` kicks off an async
    /// associated-files lookup whose result lands on the main actor after
    /// the awaiting `Task` resumes.
    private func waitFor(
        timeout: TimeInterval = 1.0,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Same as `waitFor` but for predicates that need to `await` an
    /// actor (e.g. reading from an `ActorBox`).
    private func waitForActor(
        timeout: TimeInterval = 2.0,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor ActorBox<Value: Sendable> {
    private(set) var value: Value
    init(_ initial: Value) { self.value = initial }
    func set(_ newValue: Value) { value = newValue }
}

private extension ActorBox where Value == Int {
    func increment() { value += 1 }
}
