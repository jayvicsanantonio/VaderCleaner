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

        if case .failed(let stage, _, _) = vm.phase {
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
            recycle: { _, _ in
                await recycleCalls.increment()
                return AppUninstallerViewModel.RecycleOutcome(bytesFreed: 1, bundlePermanentlyRemoved: false)
            }
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
                return AppUninstallerViewModel.RecycleOutcome(bytesFreed: 60, bundlePermanentlyRemoved: false)
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
        XCTAssertEqual(vm.phase, .complete(bytesFreed: 60, permanentRemoval: false))
        XCTAssertFalse(vm.apps.contains(where: { $0.id == app.id }))
        XCTAssertNil(vm.selectedAppID)
    }

    /// When the recycler reports the bundle was permanently removed (a
    /// root-owned app the privileged helper had to delete rather than Trash),
    /// the completion phase carries that flag so the success screen stays
    /// honest about whether the app can be restored.
    func test_uninstall_permanentRemovalOutcome_surfacedInCompletePhase() async {
        let app = makeApp(name: "Canva", bundleID: "com.canva.app")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [] },
            recycle: { _, _ in
                AppUninstallerViewModel.RecycleOutcome(bytesFreed: 5000, bundlePermanentlyRemoved: true)
            }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { vm.canUninstallSelectedApp }
        await vm.uninstall()

        XCTAssertEqual(vm.phase, .complete(bytesFreed: 5000, permanentRemoval: true))
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

        if case .failed(let stage, _, _) = vm.phase {
            XCTAssertEqual(stage, .uninstalling)
        } else {
            XCTFail("Expected .failed(.uninstalling), got \(vm.phase)")
        }
        // App row must still be present so the user can retry.
        XCTAssertTrue(vm.apps.contains(where: { $0.id == app.id }),
                      "App must stay in the list when its bundle was not Trashed")
    }

    /// An unreachable privileged helper surfaces the friendly shared copy
    /// (not the cryptic NSXPC string) AND flags the failure as a helper
    /// connection issue so the failure screen can offer to reinstall it.
    func test_uninstall_helperUnavailableSurfacesFriendlyMessageAndFlagsConnectionIssue() async {
        let app = makeApp(name: "Canva", bundleID: "com.canva.app")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [] },
            recycle: { _, _ in throw HelperConnectionError.unavailable }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { vm.canUninstallSelectedApp }
        await vm.uninstall()

        if case .failed(let stage, let message, let helperIssue) = vm.phase {
            XCTAssertEqual(stage, .uninstalling)
            XCTAssertEqual(message, HelperConnectionError.message)
            XCTAssertTrue(helperIssue, "A helper connection failure must offer the reinstall recovery")
        } else {
            XCTFail("Expected .failed(.uninstalling), got \(vm.phase)")
        }
    }

    /// A substantive (non-connection) recycle failure must NOT be flagged as a
    /// helper connection issue — the reinstall recovery would be misleading.
    func test_uninstall_nonConnectionFailureDoesNotFlagHelperIssue() async {
        struct PermissionError: LocalizedError { var errorDescription: String? { "Permission denied" } }
        let app = makeApp(name: "Helio", bundleID: "com.acme.helio")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [] },
            recycle: { _, _ in throw PermissionError() }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { vm.canUninstallSelectedApp }
        await vm.uninstall()

        if case .failed(_, let message, let helperIssue) = vm.phase {
            XCTAssertEqual(message, "Permission denied", "Substantive errors keep their own description")
            XCTAssertFalse(helperIssue)
        } else {
            XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    /// `reinstallHelper()` runs the injected re-registration and then reloads
    /// the app list so the user lands back on a usable screen to retry.
    func test_reinstallHelper_runsReregistrationThenReloads() async {
        let reinstallCalls = ActorBox(0)
        let app = makeApp(name: "Canva", bundleID: "com.canva.app")
        let vm = makeViewModel(
            discover: { _ in [app] },
            findFiles: { _ in [] },
            reinstallHelper: { await reinstallCalls.increment() }
        )

        await vm.reinstallHelper()

        let count = await reinstallCalls.value
        XCTAssertEqual(count, 1, "Reinstall must invoke the injected re-registration exactly once")
        XCTAssertEqual(vm.phase, .ready, "After reinstall the VM reloads to a usable state")
        XCTAssertTrue(vm.apps.contains(where: { $0.id == app.id }))
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
        if case .failed(let stage, _, _) = vm.phase {
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
            recycle: { _, _ in
                await calls.increment()
                return AppUninstallerViewModel.RecycleOutcome(bytesFreed: 0, bundlePermanentlyRemoved: false)
            }
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
            recycle: { _, _ in
                AppUninstallerViewModel.RecycleOutcome(bytesFreed: 0, bundlePermanentlyRemoved: false)
            }
        )
        await vm.loadApps()
        vm.select(app.id)
        await waitFor { vm.canUninstallSelectedApp }
        await vm.uninstall()
        vm.dismissResult()
        XCTAssertEqual(vm.phase, .ready)
    }

    // MARK: - recycleWithEscalation

    /// A fully user-owned app: NSWorkspace Trashes everything, so the
    /// privileged helper is never engaged and every byte is credited.
    func test_recycleWithEscalation_userOwnedApp_trashesAll_noEscalation() async throws {
        let bundle = URL(fileURLWithPath: "/Applications/Friendly.app")
        let assoc = [URL(fileURLWithPath: "/Users/me/Library/Caches/com.acme.friendly")]
        let fs = FakeFilesystem(existing: [bundle.path] + assoc.map(\.path))
        let escalateCalls = Box(0)

        let outcome = try await AppUninstallerViewModel.recycleWithEscalation(
            bundleURL: bundle,
            associatedURLs: assoc,
            recycle: { urls in
                for url in urls { fs.remove(url.path) }
                return (Set(urls.map(\.path)), nil)
            },
            escalate: { _ in escalateCalls.value += 1; return nil },
            sizeFor: { _ in [bundle.path: 100, assoc[0].path: 20] },
            exists: { fs.contains($0) }
        )

        XCTAssertEqual(outcome.bytesFreed, 120)
        XCTAssertFalse(outcome.bundlePermanentlyRemoved, "Bundle was Trashed, not permanently removed")
        XCTAssertEqual(escalateCalls.value, 0, "No escalation when everything was Trashed")
    }

    /// A root-owned / App Store bundle: NSWorkspace Trashes the user-domain
    /// residue but is denied the bundle, which is then escalated to the
    /// privileged helper for permanent removal. Bytes are credited for both.
    func test_recycleWithEscalation_rootOwnedBundle_escalatesBundleOnly_creditsBytes() async throws {
        let bundle = URL(fileURLWithPath: "/Applications/Canva.app")
        let assoc = [URL(fileURLWithPath: "/Users/me/Library/Preferences/com.canva.plist")]
        let fs = FakeFilesystem(existing: [bundle.path] + assoc.map(\.path))
        let escalated = Box<[String]>([])

        let outcome = try await AppUninstallerViewModel.recycleWithEscalation(
            bundleURL: bundle,
            associatedURLs: assoc,
            recycle: { urls in
                // The user can only Trash the user-domain associated file.
                let moved = urls.filter { $0.path.hasPrefix("/Users/") }
                for url in moved { fs.remove(url.path) }
                return (Set(moved.map(\.path)), nil)
            },
            escalate: { paths in
                escalated.value = paths
                for path in paths { fs.remove(path) } // helper permanently deletes
                return nil
            },
            sizeFor: { _ in [bundle.path: 5000, assoc[0].path: 8] },
            exists: { fs.contains($0) }
        )

        XCTAssertEqual(escalated.value, [bundle.path], "Only the unmoved bundle is escalated")
        XCTAssertEqual(outcome.bytesFreed, 5008, "Credits both the Trashed file and the helper-deleted bundle")
        XCTAssertTrue(outcome.bundlePermanentlyRemoved, "Bundle was permanently removed by the helper")
    }

    /// When the bundle survives both NSWorkspace and the privileged helper
    /// (helper unreachable / denied), the call throws so the UI reports
    /// failure rather than a false "Complete".
    func test_recycleWithEscalation_bundleSurvivesEscalation_throws() async {
        let bundle = URL(fileURLWithPath: "/Applications/Canva.app")
        let fs = FakeFilesystem(existing: [bundle.path])

        do {
            _ = try await AppUninstallerViewModel.recycleWithEscalation(
                bundleURL: bundle,
                associatedURLs: [],
                recycle: { _ in (Set<String>(), nil) },
                escalate: { _ in HelperConnectionError.unavailable }, // leaves the bundle in place
                sizeFor: { _ in [bundle.path: 100] },
                exists: { fs.contains($0) }
            )
            XCTFail("Expected a throw when the bundle survives both passes")
        } catch {
            XCTAssertTrue(error is HelperConnectionError, "Surfaces the escalation error, got \(error)")
        }
    }

    /// A surviving associated file is tolerated best-effort and is NEVER
    /// escalated to the privileged helper — only the bundle is. Once the
    /// bundle is gone the uninstall succeeds, and only removed items are
    /// credited.
    func test_recycleWithEscalation_associatedFileNotEscalated_whenBundleTrashed() async throws {
        let bundle = URL(fileURLWithPath: "/Applications/Canva.app")
        let sysFile = URL(fileURLWithPath: "/Library/LaunchDaemons/com.canva.helper.plist")
        let fs = FakeFilesystem(existing: [bundle.path, sysFile.path])
        let escalated = Box<[String]>([])

        let outcome = try await AppUninstallerViewModel.recycleWithEscalation(
            bundleURL: bundle,
            associatedURLs: [sysFile],
            recycle: { _ in
                fs.remove(bundle.path) // bundle Trashed, system file denied
                return (Set([bundle.path]), nil)
            },
            escalate: { paths in escalated.value = paths; return nil },
            sizeFor: { _ in [bundle.path: 5000, sysFile.path: 9] },
            exists: { fs.contains($0) }
        )

        XCTAssertTrue(escalated.value.isEmpty, "Associated files must never be escalated for permanent deletion")
        XCTAssertEqual(outcome.bytesFreed, 5000, "Only the removed bundle is credited; the surviving file is not")
        XCTAssertFalse(outcome.bundlePermanentlyRemoved, "Bundle was Trashed by NSWorkspace, not escalated")
    }

    // MARK: - List metrics cache

    /// `loadListMetrics()` populates the session-scoped per-app size and
    /// last-opened caches the manager's uninstaller list sorts and renders by.
    func test_loadListMetrics_populatesSizesAndDates() async {
        let appA = makeApp(name: "Alpha", bundleID: "com.acme.alpha")
        let appB = makeApp(name: "Bravo", bundleID: "com.acme.bravo")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let vm = makeViewModel(
            discover: { _ in [appA, appB] },
            measureListMetrics: { apps in
                var sizes: [AppInfo.ID: Int64] = [:]
                var dates: [AppInfo.ID: Date] = [:]
                for app in apps {
                    sizes[app.id] = 1_000
                    dates[app.id] = date
                }
                return (sizes, dates)
            }
        )
        await vm.loadApps()
        await vm.loadListMetrics()

        XCTAssertEqual(vm.listSizes[appA.id], 1_000)
        XCTAssertEqual(vm.listSizes[appB.id], 1_000)
        XCTAssertEqual(vm.listLastOpened[appA.id], date)
        XCTAssertEqual(vm.listLastOpened[appB.id], date)
    }

    /// The metrics walk is the expensive pass, so once an app is measured it is
    /// never re-measured for the session — reopening the manager reuses the
    /// cache instead of re-walking the disk.
    func test_loadListMetrics_isIdempotent_skipsAlreadyMeasured() async {
        let app = makeApp(name: "Alpha", bundleID: "com.acme.alpha")
        let measuredApps = ActorBox<[[AppInfo.ID]]>([])
        let vm = makeViewModel(
            discover: { _ in [app] },
            measureListMetrics: { apps in
                await measuredApps.mutate { $0.append(apps.map(\.id)) }
                return (Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Int64(1)) }), [:])
            }
        )
        await vm.loadApps()
        await vm.loadListMetrics()
        await vm.loadListMetrics()

        let calls = await measuredApps.value
        XCTAssertEqual(calls.count, 1, "The second call must find every app cached and skip the walk")
    }

    /// New apps that appear after a reload are measured without re-walking the
    /// apps already cached.
    func test_loadListMetrics_measuresOnlyNewlyAppearedApps() async {
        let appA = makeApp(name: "Alpha", bundleID: "com.acme.alpha")
        let appB = makeApp(name: "Bravo", bundleID: "com.acme.bravo")
        let measuredApps = ActorBox<[[AppInfo.ID]]>([])
        var roster = [appA]
        let vm = makeViewModel(
            discover: { _ in roster },
            measureListMetrics: { apps in
                await measuredApps.mutate { $0.append(apps.map(\.id)) }
                return (Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Int64(1)) }), [:])
            }
        )
        await vm.loadApps()
        await vm.loadListMetrics()

        roster = [appA, appB]
        await vm.reloadApps()
        await vm.loadListMetrics()

        let calls = await measuredApps.value
        XCTAssertEqual(calls, [[appA.id], [appB.id]], "Only the newly-appeared app is measured on the second pass")
        XCTAssertEqual(vm.listSizes[appA.id], 1)
        XCTAssertEqual(vm.listSizes[appB.id], 1)
    }

    /// Each batch of freshly-measured metrics bumps the revision so the
    /// manager's memoized list recomputes its order once the values land.
    func test_loadListMetrics_bumpsRevisionWhenMetricsLand() async {
        let app = makeApp(name: "Alpha", bundleID: "com.acme.alpha")
        let vm = makeViewModel(
            discover: { _ in [app] },
            measureListMetrics: { apps in
                (Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Int64(1)) }), [:])
            }
        )
        let before = vm.listMetricsRevision
        await vm.loadApps()
        await vm.loadListMetrics()
        XCTAssertEqual(vm.listMetricsRevision, before + 1)

        // No pending apps the second time — nothing lands, revision is steady.
        await vm.loadListMetrics()
        XCTAssertEqual(vm.listMetricsRevision, before + 1)
    }

    // MARK: - Helpers

    private func makeViewModel(
        discover: @escaping AppUninstallerViewModel.Discover = { _ in [] },
        findFiles: @escaping AppUninstallerViewModel.FindFiles = { _ in [] },
        measureSize: @escaping AppUninstallerViewModel.MeasureSize = { _ in 0 },
        measureListMetrics: @escaping AppUninstallerViewModel.MeasureListMetrics = { _ in ([:], [:]) },
        recycle: @escaping AppUninstallerViewModel.Recycle = { _, _ in
            AppUninstallerViewModel.RecycleOutcome(bytesFreed: 0, bundlePermanentlyRemoved: false)
        },
        reinstallHelper: @escaping AppUninstallerViewModel.ReinstallHelper = {}
    ) -> AppUninstallerViewModel {
        AppUninstallerViewModel(
            discover: discover,
            findFiles: findFiles,
            measureSize: measureSize,
            measureListMetrics: measureListMetrics,
            recycle: recycle,
            reinstallHelper: reinstallHelper
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
    func mutate(_ body: (inout Value) -> Void) { body(&value) }
}

private extension ActorBox where Value == Int {
    func increment() { value += 1 }
}

/// In-memory existence model for `recycleWithEscalation` tests. The `recycle`
/// and `escalate` fakes mutate it so the post-pass `exists` checks observe the
/// same state transitions a real filesystem would.
private final class FakeFilesystem {
    private var existing: Set<String>
    init(existing: [String]) { self.existing = Set(existing) }
    func contains(_ path: String) -> Bool { existing.contains(path) }
    func remove(_ path: String) { existing.remove(path) }
}

/// Mutable reference cell for capturing call counts / arguments from the
/// non-escaping fakes passed to `recycleWithEscalation`.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
