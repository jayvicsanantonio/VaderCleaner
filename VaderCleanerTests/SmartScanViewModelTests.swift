// SmartScanViewModelTests.swift
// Drives the SmartScanViewModel state machine — concurrent junk/malware/login orchestration, result aggregation, and the unified clean() delegation — through injected fakes.

import XCTest
@testable import VaderCleaner

@MainActor
final class SmartScanViewModelTests: XCTestCase {

    private let threat = MalwareThreat(
        filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil.bin"),
        threatName: "Eicar-Test-Signature"
    )

    private let loginItem = LoginItem(id: "com.example.helper", name: "Example Helper", isEnabled: true)

    private let largeFile = ScannedFile(
        url: URL(fileURLWithPath: "/Users/me/Movies/very-old-trip.mov"),
        size: 5_000_000_000,
        lastAccessDate: nil,
        lastModifiedDate: nil,
        category: .userCache
    )

    private let availableUpdate = UpdateInfo(
        appName: "Example",
        bundleID: "com.example.app",
        bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
        installedVersion: "1.0",
        latestVersion: "2.0",
        source: .sparkle,
        updateURL: URL(string: "https://example.com/example.zip")!
    )

    // MARK: - Initial state

    func test_init_phaseIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
    }

    // MARK: - Scan: orchestration

    func test_scan_runsAllThreeSubScans() async {
        var ranJunk = false
        var ranMalware = false
        var ranLogin = false
        let vm = makeViewModel(
            junkScanner: { ranJunk = true; return ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { ranMalware = true; return [] },
            loginItemsLoader: { ranLogin = true; return [] }
        )

        await vm.scan()

        XCTAssertTrue(ranJunk, "Smart Scan must run the System Junk scan")
        XCTAssertTrue(ranMalware, "Smart Scan must run the Malware scan when ClamAV is installed")
        XCTAssertTrue(ranLogin, "Smart Scan must read login items")
    }

    func test_scan_aggregatesResultsFromAllThreeSources() async {
        let junk = makeResult((.userCache, [makeFile(name: "a", size: 100, category: .userCache)]))
        let vm = makeViewModel(
            junkScanner: { junk },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            loginItemsLoader: { [self.loginItem] }
        )

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.junkResult, junk)
        XCTAssertEqual(result.threats, [threat])
        XCTAssertEqual(result.optimizationItems, [loginItem])
        XCTAssertTrue(result.clamAVAvailable)
    }

    func test_scan_reportsTotalJunkBytes() async {
        let junk = makeResult(
            (.userCache, [makeFile(name: "a", size: 100, category: .userCache)]),
            (.userLogs, [makeFile(name: "b", size: 250, category: .userLogs)])
        )
        let vm = makeViewModel(junkScanner: { junk })

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.totalJunkBytes, 350)
    }

    func test_scan_exposesPerModuleResults() async {
        let junk = makeResult((.trash, [makeFile(name: "t", size: 42, category: .trash)]))
        let second = MalwareThreat(
            filePath: URL(fileURLWithPath: "/Users/me/Library/Caches/x"),
            threatName: "Adware"
        )
        let vm = makeViewModel(
            junkScanner: { junk },
            malwareInstalled: { true },
            malwareScanner: { [self.threat, second] },
            loginItemsLoader: { [self.loginItem] }
        )

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.junkResult.totalSize, 42)
        XCTAssertEqual(result.threats.count, 2)
        XCTAssertEqual(result.optimizationItems.count, 1)
    }

    func test_scan_whenClamAVNotInstalled_skipsMalwareScanAndMarksUnavailable() async {
        var ranMalware = false
        let vm = makeViewModel(
            junkScanner: { ScanResult(items: []) },
            malwareInstalled: { false },
            malwareScanner: { ranMalware = true; return [self.threat] },
            loginItemsLoader: { [] }
        )

        await vm.scan()

        XCTAssertFalse(ranMalware, "Malware scan must be skipped when ClamAV is not installed")
        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertFalse(result.clamAVAvailable)
        XCTAssertEqual(result.threats, [])
    }

    func test_scan_junkFailure_movesToFailed() async {
        struct Boom: Error {}
        let vm = makeViewModel(junkScanner: { throw Boom() })

        await vm.scan()

        guard case .failed = vm.phase else {
            return XCTFail("Expected .failed, got \(vm.phase)")
        }
    }

    func test_scan_emptyEverywhere_stillLandsInResults() async {
        let vm = makeViewModel(
            junkScanner: { ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { [] },
            loginItemsLoader: { [] }
        )

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.totalJunkBytes, 0)
        XCTAssertEqual(result.threats, [])
        XCTAssertEqual(result.optimizationItems, [])
    }

    func test_scan_populatesLargeOldFilesFromScanner() async {
        var ranLargeOldFiles = false
        let vm = makeViewModel(
            largeOldFilesScanner: {
                ranLargeOldFiles = true
                return [self.largeFile]
            }
        )

        await vm.scan()

        XCTAssertTrue(ranLargeOldFiles, "Smart Scan must run the Large & Old Files scan")
        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.largeOldFiles, [largeFile])
    }

    func test_scan_populatesAvailableUpdatesFromChecker() async {
        var ranUpdates = false
        let vm = makeViewModel(
            updatesChecker: {
                ranUpdates = true
                return [self.availableUpdate]
            }
        )

        await vm.scan()

        XCTAssertTrue(ranUpdates, "Smart Scan must run the App Updater check")
        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.availableUpdates, [availableUpdate])
    }

    func test_scan_emptyLargeOldFilesAndUpdates_defaultEmpty() async {
        let vm = makeViewModel()

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.largeOldFiles, [])
        XCTAssertEqual(result.availableUpdates, [])
    }

    func test_scan_ignoresReentryWhileAScanIsInFlight() async {
        var junkInvocations = 0
        var resume: CheckedContinuation<Void, Never>?
        let vm = makeViewModel(
            junkScanner: {
                junkInvocations += 1
                await withCheckedContinuation { resume = $0 }
                return ScanResult(items: [])
            }
        )

        let inFlight = Task { await vm.scan() }
        // Yield until the first scan has entered the scanner and suspended.
        while resume == nil { await Task.yield() }

        // A second scan() while one is in flight must be a no-op.
        await vm.scan()
        XCTAssertEqual(junkInvocations, 1,
                       "A re-entrant scan() while a scan is in flight must be ignored")

        resume?.resume()
        await inFlight.value
        XCTAssertEqual(junkInvocations, 1)
    }

    // MARK: - Tile selection

    func test_init_tileSelectionIsEmpty() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.tileSelection, [])
    }

    func test_scan_defaultsTileSelectionToModulesWithCleanableWork() async {
        // Junk has bytes, malware has a threat, updates has one entry, large
        // old files has one entry, login items has one — every module should
        // default to checked. Optimization additionally is always actionable
        // (maintenance scripts always available on macOS), so it is also on.
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 100, category: .userCache)])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            loginItemsLoader: { [self.loginItem] },
            largeOldFilesScanner: { [self.largeFile] },
            updatesChecker: { [self.availableUpdate] }
        )

        await vm.scan()

        XCTAssertEqual(vm.tileSelection, Set(SmartScanModule.allCases))
    }

    func test_scan_defaultsTileSelectionExcludesModulesWithoutWork() async {
        // Junk has bytes, but every other module is empty. Optimization
        // stays on because maintenance scripts are always actionable.
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 100, category: .userCache)])) }
        )

        await vm.scan()

        XCTAssertEqual(vm.tileSelection, [.systemJunk, .optimization])
    }

    func test_scan_defaultsTileSelectionEmptyExceptOptimizationWhenNothingFound() async {
        let vm = makeViewModel()

        await vm.scan()

        XCTAssertEqual(vm.tileSelection, [.optimization])
    }

    func test_toggleModule_addsThenRemovesFromSelection() async {
        let vm = makeViewModel()
        await vm.scan()
        // Optimization is on by default.
        XCTAssertTrue(vm.isModuleSelected(.optimization))

        vm.toggleModule(.optimization)
        XCTAssertFalse(vm.isModuleSelected(.optimization))

        vm.toggleModule(.optimization)
        XCTAssertTrue(vm.isModuleSelected(.optimization))
    }

    func test_reset_clearsTileSelection() async {
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 1, category: .userCache)])) }
        )
        await vm.scan()
        XCTAssertFalse(vm.tileSelection.isEmpty)

        vm.reset()

        XCTAssertEqual(vm.tileSelection, [])
    }

    // MARK: - Sub-selections

    func test_scan_defaultsJunkCategorySelectionToAllCategoriesWithItems() async {
        let vm = makeViewModel(
            junkScanner: {
                self.makeResult(
                    (.userCache, [self.makeFile(name: "a", size: 1, category: .userCache)]),
                    (.userLogs, [self.makeFile(name: "b", size: 2, category: .userLogs)])
                )
            }
        )

        await vm.scan()

        XCTAssertEqual(vm.junkCategorySelection, [.userCache, .userLogs])
    }

    func test_scan_defaultsThreatSelectionToAllDetectedThreats() async {
        let second = MalwareThreat(
            filePath: URL(fileURLWithPath: "/Library/Caches/x"),
            threatName: "OSX.Bad"
        )
        let vm = makeViewModel(
            malwareInstalled: { true },
            malwareScanner: { [self.threat, second] }
        )

        await vm.scan()

        XCTAssertEqual(vm.threatSelection, [threat.filePath, second.filePath])
    }

    func test_scan_defaultsUpdateSelectionToAllAvailableUpdates() async {
        let vm = makeViewModel(
            updatesChecker: { [self.availableUpdate] }
        )

        await vm.scan()

        XCTAssertEqual(vm.updateSelection, [availableUpdate.bundleID])
    }

    func test_scan_defaultsLargeFileSelectionToEmpty() async {
        // Destructive deletes mirror `LargeOldFilesViewModel`'s contract:
        // nothing is selected by default — the user must explicitly opt
        // individual files into removal via the Review screen.
        let vm = makeViewModel(
            largeOldFilesScanner: { [self.largeFile] }
        )

        await vm.scan()

        XCTAssertEqual(vm.largeFileSelection, [])
    }

    func test_toggleJunkCategory_addsAndRemoves() async {
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 1, category: .userCache)])) }
        )
        await vm.scan()
        XCTAssertTrue(vm.isJunkCategorySelected(.userCache))

        vm.toggleJunkCategory(.userCache)
        XCTAssertFalse(vm.isJunkCategorySelected(.userCache))

        vm.toggleJunkCategory(.userCache)
        XCTAssertTrue(vm.isJunkCategorySelected(.userCache))
    }

    func test_scan_defaultsJunkFileSelectionToAllScannedFiles() async {
        let a = makeFile(name: "a", size: 1, category: .userCache)
        let b = makeFile(name: "b", size: 2, category: .userLogs)
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [a]), (.userLogs, [b])) }
        )

        await vm.scan()

        XCTAssertEqual(vm.junkFileSelection, [a.url, b.url],
                       "Cleanup Manager opens with every junk file checked")
    }

    func test_toggleJunkFile_addsAndRemoves() async {
        let a = makeFile(name: "a", size: 1, category: .userCache)
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [a])) }
        )
        await vm.scan()
        XCTAssertTrue(vm.isJunkFileSelected(a))

        vm.toggleJunkFile(a)
        XCTAssertFalse(vm.isJunkFileSelected(a))

        vm.toggleJunkFile(a)
        XCTAssertTrue(vm.isJunkFileSelected(a))
    }

    /// A category facade toggle is a bulk op over its files: deselecting one
    /// file makes the category read as unselected, and toggling the category
    /// re-selects every file in it.
    func test_toggleJunkCategory_togglesEveryFileInCategory() async {
        let a = makeFile(name: "a", size: 1, category: .userCache)
        let b = makeFile(name: "b", size: 2, category: .userCache)
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [a, b])) }
        )
        await vm.scan()
        XCTAssertTrue(vm.isJunkCategorySelected(.userCache))

        // Deselecting a single file drops the category out of the derived set.
        vm.toggleJunkFile(a)
        XCTAssertFalse(vm.isJunkCategorySelected(.userCache))

        // Toggling the partially-selected category selects all its files.
        vm.toggleJunkCategory(.userCache)
        XCTAssertTrue(vm.isJunkFileSelected(a))
        XCTAssertTrue(vm.isJunkFileSelected(b))
        XCTAssertTrue(vm.isJunkCategorySelected(.userCache))
    }

    /// Run cleans exactly the files left checked, at per-file granularity —
    /// deselecting one file in a category keeps the rest.
    func test_run_filtersJunkItemsByFileSelection() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 200, category: .userCache)
        var receivedFiles: [ScannedFile] = []
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [a, b])) },
            junkCleaner: { files in receivedFiles = files; return 0 }
        )
        await vm.scan()
        vm.toggleJunkFile(a)   // uncheck one file within the category

        await vm.run()

        XCTAssertEqual(receivedFiles, [b],
                       "Only files left checked may be handed to the cleaner")
    }

    func test_setJunkCategory_selectsAndClearsEveryFileInCategory() async {
        let a = makeFile(name: "a", size: 1, category: .userCache)
        let b = makeFile(name: "b", size: 2, category: .userCache)
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [a, b])) }
        )
        await vm.scan()

        vm.setJunkCategory(.userCache, selected: false)
        XCTAssertFalse(vm.isJunkFileSelected(a))
        XCTAssertFalse(vm.isJunkFileSelected(b))

        vm.setJunkCategory(.userCache, selected: true)
        XCTAssertTrue(vm.isJunkFileSelected(a))
        XCTAssertTrue(vm.isJunkFileSelected(b))
    }

    func test_setAllThreats_selectsAndClearsEveryThreat() async {
        let second = MalwareThreat(filePath: URL(fileURLWithPath: "/Library/Caches/x"), threatName: "OSX.Bad")
        let vm = makeViewModel(
            malwareInstalled: { true },
            malwareScanner: { [self.threat, second] }
        )
        await vm.scan()

        vm.setAllThreats(selected: false)
        XCTAssertEqual(vm.threatSelection, [])

        vm.setAllThreats(selected: true)
        XCTAssertEqual(vm.threatSelection, [threat.filePath, second.filePath])
    }

    func test_setAllUpdates_selectsAndClearsEveryUpdate() async {
        let vm = makeViewModel(updatesChecker: { [self.availableUpdate] })
        await vm.scan()

        vm.setAllUpdates(selected: false)
        XCTAssertEqual(vm.updateSelection, [])

        vm.setAllUpdates(selected: true)
        XCTAssertEqual(vm.updateSelection, [availableUpdate.bundleID])
    }

    func test_setLargeFiles_selectsAndClearsTheGivenURLs() async {
        let vm = makeViewModel(largeOldFilesScanner: { [self.largeFile] })
        await vm.scan()
        XCTAssertEqual(vm.largeFileSelection, [], "Clutter starts opt-in (empty)")

        vm.setLargeFiles([largeFile.url], selected: true)
        XCTAssertTrue(vm.isLargeFileSelected(largeFile))

        vm.setLargeFiles([largeFile.url], selected: false)
        XCTAssertFalse(vm.isLargeFileSelected(largeFile))
    }

    func test_toggleThreat_addsAndRemoves() async {
        let vm = makeViewModel(
            malwareInstalled: { true },
            malwareScanner: { [self.threat] }
        )
        await vm.scan()
        XCTAssertTrue(vm.isThreatSelected(threat))

        vm.toggleThreat(threat)
        XCTAssertFalse(vm.isThreatSelected(threat))

        vm.toggleThreat(threat)
        XCTAssertTrue(vm.isThreatSelected(threat))
    }

    func test_toggleUpdate_addsAndRemoves() async {
        let vm = makeViewModel(
            updatesChecker: { [self.availableUpdate] }
        )
        await vm.scan()
        XCTAssertTrue(vm.isUpdateSelected(availableUpdate))

        vm.toggleUpdate(availableUpdate)
        XCTAssertFalse(vm.isUpdateSelected(availableUpdate))

        vm.toggleUpdate(availableUpdate)
        XCTAssertTrue(vm.isUpdateSelected(availableUpdate))
    }

    func test_scan_cachesLargeOldFilesSortedBySizeDescending() async {
        let small = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Movies/small.mov"),
            size: 1_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
        let big = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Movies/big.mov"),
            size: 5_000_000_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
        let mid = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Movies/mid.mov"),
            size: 50_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
        let vm = makeViewModel(
            largeOldFilesScanner: { [small, big, mid] }
        )

        await vm.scan()

        XCTAssertEqual(
            vm.sortedLargeOldFiles.map(\.url),
            [big.url, mid.url, small.url],
            "Sort cache must rank large/old files biggest-first so the Review list opens on the most reclaimable thing"
        )
    }

    func test_reset_clearsSortedLargeOldFilesCache() async {
        let vm = makeViewModel(largeOldFilesScanner: { [self.largeFile] })
        await vm.scan()
        XCTAssertFalse(vm.sortedLargeOldFiles.isEmpty)

        vm.reset()

        XCTAssertTrue(vm.sortedLargeOldFiles.isEmpty)
    }

    func test_selectAllLargeFiles_optsEveryDetectedFileInWithOneWrite() async {
        let other = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Movies/other.mov"),
            size: 100_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
        let vm = makeViewModel(largeOldFilesScanner: { [self.largeFile, other] })
        await vm.scan()
        XCTAssertTrue(vm.largeFileSelection.isEmpty)

        vm.selectAllLargeFiles()

        XCTAssertEqual(vm.largeFileSelection, [largeFile.url, other.url])
    }

    func test_selectAllLargeFiles_outsideResults_isNoop() {
        let vm = makeViewModel()
        // `.idle` — never scanned.
        vm.selectAllLargeFiles()
        XCTAssertTrue(vm.largeFileSelection.isEmpty)
    }

    func test_clearLargeFileSelection_emptiesTheSet() async {
        let vm = makeViewModel(largeOldFilesScanner: { [self.largeFile] })
        await vm.scan()
        vm.selectAllLargeFiles()
        XCTAssertFalse(vm.largeFileSelection.isEmpty)

        vm.clearLargeFileSelection()

        XCTAssertTrue(vm.largeFileSelection.isEmpty)
    }

    func test_toggleLargeFile_addsAndRemoves() async {
        let vm = makeViewModel(
            largeOldFilesScanner: { [self.largeFile] }
        )
        await vm.scan()
        XCTAssertFalse(vm.isLargeFileSelected(largeFile))

        vm.toggleLargeFile(largeFile)
        XCTAssertTrue(vm.isLargeFileSelected(largeFile))

        vm.toggleLargeFile(largeFile)
        XCTAssertFalse(vm.isLargeFileSelected(largeFile))
    }

    func test_reset_clearsAllSubSelections() async {
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 1, category: .userCache)])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            largeOldFilesScanner: { [self.largeFile] },
            updatesChecker: { [self.availableUpdate] }
        )
        await vm.scan()
        vm.toggleLargeFile(largeFile)
        XCTAssertFalse(vm.junkCategorySelection.isEmpty)
        XCTAssertFalse(vm.threatSelection.isEmpty)
        XCTAssertFalse(vm.updateSelection.isEmpty)
        XCTAssertFalse(vm.largeFileSelection.isEmpty)

        vm.reset()

        XCTAssertTrue(vm.junkCategorySelection.isEmpty)
        XCTAssertTrue(vm.threatSelection.isEmpty)
        XCTAssertTrue(vm.updateSelection.isEmpty)
        XCTAssertTrue(vm.largeFileSelection.isEmpty)
    }

    // MARK: - Run: delegation + selection gating

    func test_run_delegatesToJunkCleanerAndThreatRemover() async {
        let junkFile = makeFile(name: "a", size: 100, category: .userCache)
        var cleanedFiles: [ScannedFile] = []
        var removedThreats: [MalwareThreat] = []
        var disabledLoginItems: [LoginItem] = []
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [junkFile])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            loginItemsLoader: { [self.loginItem] },
            junkCleaner: { files in cleanedFiles = files; return 100 },
            threatRemover: { threats in removedThreats = threats; return [] }
        )
        await vm.scan()

        await vm.run()

        XCTAssertEqual(cleanedFiles, [junkFile], "run() must hand the scanned junk files to the junk cleaner")
        XCTAssertEqual(removedThreats, [threat], "run() must hand the detected threats to the threat remover")
        XCTAssertTrue(disabledLoginItems.isEmpty,
                      "run() must NOT auto-disable login items — Optimization wires the maintenance-script action, not login-item changes")
    }

    func test_run_reportsSummary() async {
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 100, category: .userCache)])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            loginItemsLoader: { [] },
            junkCleaner: { _ in 2_048 },
            threatRemover: { _ in [] }
        )
        await vm.scan()
        // Deselect Optimization so the summary line stays focused on the
        // junk/malware result for this assertion — Optimization wiring is
        // covered by its own tests below.
        vm.toggleModule(.optimization)

        await vm.run()

        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.bytesFreed, 2_048)
        XCTAssertEqual(summary.threatsRemoved, 1)
        XCTAssertTrue(summary.failedModules.isEmpty)
    }

    func test_run_partialThreatFailure_reportsRemovedCount() async {
        let second = MalwareThreat(
            filePath: URL(fileURLWithPath: "/Library/Caches/x"),
            threatName: "OSX.Bad"
        )
        let vm = makeViewModel(
            junkScanner: { ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat, second] },
            loginItemsLoader: { [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [second] }   // second could not be removed
        )
        await vm.scan()
        vm.toggleModule(.optimization)

        await vm.run()

        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.bytesFreed, 0)
        XCTAssertEqual(summary.threatsRemoved, 1)
    }

    func test_run_junkFailure_landsDoneAndRecordsFailureInSummary() async {
        // Per Open Decision 1: per-module failure must not collapse the
        // whole Run to .failed. Other modules' successes still need to
        // survive — the summary records which modules failed so the done
        // screen can surface a warning while still showing what succeeded.
        struct Boom: Error {}
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 1, category: .userCache)])) },
            junkCleaner: { _ in throw Boom() }
        )
        await vm.scan()

        await vm.run()

        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.bytesFreed, 0)
        XCTAssertTrue(summary.failedModules.contains(.systemJunk),
                      "A junk cleaner throw must be recorded in summary.failedModules")
    }

    func test_run_whenNotInResults_isNoop() async {
        var cleaned = false
        let vm = makeViewModel(junkCleaner: { _ in cleaned = true; return 0 })

        await vm.run()

        XCTAssertFalse(cleaned, "run() before a scan must be a no-op")
        XCTAssertEqual(vm.phase, .idle)
    }

    func test_run_skipsSystemJunkWhenTileDeselected() async {
        let junkFile = makeFile(name: "a", size: 100, category: .userCache)
        var junkCalls = 0
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [junkFile])) },
            junkCleaner: { _ in junkCalls += 1; return 100 }
        )
        await vm.scan()
        vm.toggleModule(.systemJunk)   // deselect

        await vm.run()

        XCTAssertEqual(junkCalls, 0, "Deselecting the System Junk tile must skip the junk cleaner entirely")
        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.bytesFreed, 0)
    }

    func test_run_skipsMalwareWhenTileDeselected() async {
        var removerCalls = 0
        let vm = makeViewModel(
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            threatRemover: { _ in removerCalls += 1; return [] }
        )
        await vm.scan()
        vm.toggleModule(.malware)   // deselect

        await vm.run()

        XCTAssertEqual(removerCalls, 0, "Deselecting the Malware tile must skip the threat remover entirely")
        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.threatsRemoved, 0)
    }

    func test_run_filtersJunkItemsByCategorySelection() async {
        let cacheFile = makeFile(name: "a", size: 100, category: .userCache)
        let logFile = makeFile(name: "b", size: 200, category: .userLogs)
        var receivedFiles: [ScannedFile] = []
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [cacheFile]), (.userLogs, [logFile])) },
            junkCleaner: { files in receivedFiles = files; return 0 }
        )
        await vm.scan()
        vm.toggleJunkCategory(.userLogs)   // deselect logs only

        await vm.run()

        XCTAssertEqual(receivedFiles, [cacheFile],
                       "Deselected categories must not have their files passed to the cleaner")
    }

    func test_run_filtersThreatsByThreatSelection() async {
        let second = MalwareThreat(
            filePath: URL(fileURLWithPath: "/Library/Caches/x"),
            threatName: "OSX.Bad"
        )
        var receivedThreats: [MalwareThreat] = []
        let vm = makeViewModel(
            malwareInstalled: { true },
            malwareScanner: { [self.threat, second] },
            threatRemover: { threats in receivedThreats = threats; return [] }
        )
        await vm.scan()
        vm.toggleThreat(second)   // deselect the second threat only

        await vm.run()

        XCTAssertEqual(receivedThreats, [threat],
                       "Deselected threats must not be passed to the remover")
    }

    func test_run_skipsJunkCleanerWhenSelectionDrainsToEmpty() async {
        let junkFile = makeFile(name: "a", size: 100, category: .userCache)
        var junkCalls = 0
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [junkFile])) },
            junkCleaner: { _ in junkCalls += 1; return 100 }
        )
        await vm.scan()
        // Tile still on, but the user deselected every category — the
        // filter empties out and the cleaner must not be called with `[]`.
        vm.toggleJunkCategory(.userCache)

        await vm.run()

        XCTAssertEqual(junkCalls, 0)
    }

    func test_run_noTilesSelected_landsDoneWithEmptySummary() async {
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 1, category: .userCache)])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] }
        )
        await vm.scan()
        for module in SmartScanModule.allCases where vm.isModuleSelected(module) {
            vm.toggleModule(module)
        }

        await vm.run()

        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.bytesFreed, 0)
        XCTAssertEqual(summary.threatsRemoved, 0)
        XCTAssertNil(summary.maintenanceOutput)
        XCTAssertEqual(summary.updatesOpened, 0)
        XCTAssertEqual(summary.clutterFilesRemoved, 0)
        XCTAssertEqual(summary.clutterBytesRemoved, 0)
        XCTAssertTrue(summary.failedModules.isEmpty)
    }

    // MARK: - Run: Optimization (maintenance scripts)

    func test_run_runsMaintenanceWhenOptimizationSelected() async {
        var ranMaintenance = false
        let vm = makeViewModel(
            maintenanceRunner: {
                ranMaintenance = true
                return "ran"
            }
        )
        await vm.scan()
        // Optimization defaults on with maintenance.

        await vm.run()

        XCTAssertTrue(ranMaintenance)
        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.maintenanceOutput, "ran")
    }

    func test_run_skipsMaintenanceWhenOptimizationDeselected() async {
        var ranMaintenance = false
        let vm = makeViewModel(
            maintenanceRunner: {
                ranMaintenance = true
                return "ran"
            }
        )
        await vm.scan()
        vm.toggleModule(.optimization)   // deselect

        await vm.run()

        XCTAssertFalse(ranMaintenance)
        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertNil(summary.maintenanceOutput)
    }

    func test_run_maintenanceFailure_landsDoneAndRecordsFailureInSummary() async {
        struct Boom: Error {}
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 100, category: .userCache)])) },
            junkCleaner: { _ in 2_048 },
            maintenanceRunner: { throw Boom() }
        )
        await vm.scan()

        await vm.run()

        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.bytesFreed, 2_048, "Junk must still clean even when maintenance fails")
        XCTAssertNil(summary.maintenanceOutput)
        XCTAssertTrue(summary.failedModules.contains(.optimization))
    }

    // MARK: - Run: Applications (open selected updates)

    func test_run_opensSelectedUpdatesWhenApplicationsSelected() async {
        var openedURLs: [URL] = []
        let vm = makeViewModel(
            updatesChecker: { [self.availableUpdate] },
            updateOpener: { openedURLs.append($0) }
        )
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.applications))

        await vm.run()

        XCTAssertEqual(openedURLs, [availableUpdate.updateURL])
        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.updatesOpened, 1)
    }

    func test_run_skipsApplicationsWhenTileDeselected() async {
        var openedURLs: [URL] = []
        let vm = makeViewModel(
            updatesChecker: { [self.availableUpdate] },
            updateOpener: { openedURLs.append($0) }
        )
        await vm.scan()
        vm.toggleModule(.applications)

        await vm.run()

        XCTAssertEqual(openedURLs, [])
    }

    func test_run_skipsDeselectedUpdates() async {
        let second = UpdateInfo(
            appName: "Other",
            bundleID: "com.example.other",
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: .appStore,
            updateURL: URL(string: "macappstore://apps.apple.com/app/id1")!
        )
        var openedURLs: [URL] = []
        let vm = makeViewModel(
            updatesChecker: { [self.availableUpdate, second] },
            updateOpener: { openedURLs.append($0) }
        )
        await vm.scan()
        vm.toggleUpdate(second)   // deselect the second update only

        await vm.run()

        XCTAssertEqual(openedURLs, [availableUpdate.updateURL])
    }

    // MARK: - Run: My Clutter (delete selected large files)

    func test_run_deletesSelectedLargeFiles() async {
        var receivedURLs: [URL] = []
        let vm = makeViewModel(
            largeOldFilesScanner: { [self.largeFile] },
            largeFileDeleter: { urls in
                receivedURLs = urls
                return Set(urls)
            }
        )
        await vm.scan()
        vm.toggleLargeFile(largeFile)   // opt the file in

        await vm.run()

        XCTAssertEqual(receivedURLs, [largeFile.url])
        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.clutterFilesRemoved, 1)
        XCTAssertEqual(summary.clutterBytesRemoved, largeFile.size)
    }

    func test_run_skipsMyClutterWhenNothingSelected() async {
        // Tile is selected by default (largeOldFiles non-empty), but no
        // individual file is opted in — deleter must NOT be called with [].
        var deleterCalls = 0
        let vm = makeViewModel(
            largeOldFilesScanner: { [self.largeFile] },
            largeFileDeleter: { _ in deleterCalls += 1; return [] }
        )
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.myClutter))
        XCTAssertTrue(vm.largeFileSelection.isEmpty)

        await vm.run()

        XCTAssertEqual(deleterCalls, 0)
    }

    func test_run_recordsClutterPartialSuccess() async {
        let other = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Movies/locked.mov"),
            size: 9_000_000_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .userCache
        )
        let vm = makeViewModel(
            largeOldFilesScanner: { [self.largeFile, other] },
            // Deleter reports only `largeFile` as actually removed — `other`
            // was locked / permission-denied.
            largeFileDeleter: { _ in [self.largeFile.url] }
        )
        await vm.scan()
        vm.toggleLargeFile(largeFile)
        vm.toggleLargeFile(other)

        await vm.run()

        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.clutterFilesRemoved, 1)
        XCTAssertEqual(summary.clutterBytesRemoved, largeFile.size)
    }

    // MARK: - Executable work surface

    func test_hasExecutableWork_falseAtIdle() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.hasExecutableWork)
    }

    func test_hasExecutableWork_trueAtResultsWithOptimizationOn() async {
        let vm = makeViewModel()
        await vm.scan()
        // Optimization defaults on with always-actionable maintenance, so a
        // freshly-landed scan with zero other work still has executable work.
        XCTAssertTrue(vm.hasExecutableWork)
    }

    func test_hasExecutableWork_falseAfterDeselectingEveryTile() async {
        let vm = makeViewModel()
        await vm.scan()
        for module in SmartScanModule.allCases where vm.isModuleSelected(module) {
            vm.toggleModule(module)
        }
        XCTAssertFalse(vm.hasExecutableWork)
    }

    func test_willExecute_systemJunkRespectsCategorySelection() async {
        let cacheFile = makeFile(name: "a", size: 100, category: .userCache)
        let logFile = makeFile(name: "b", size: 200, category: .userLogs)
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [cacheFile]), (.userLogs, [logFile])) }
        )
        await vm.scan()
        XCTAssertTrue(vm.willExecute(.systemJunk))

        // Deselect every category → systemJunk has no work.
        vm.toggleJunkCategory(.userCache)
        vm.toggleJunkCategory(.userLogs)
        XCTAssertFalse(vm.willExecute(.systemJunk))
    }

    func test_willExecute_myClutterRequiresAtLeastOneFileSelected() async {
        let vm = makeViewModel(largeOldFilesScanner: { [self.largeFile] })
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.myClutter))
        // Largeold files defaults to nothing selected — tile is on, no work.
        XCTAssertFalse(vm.willExecute(.myClutter))

        vm.toggleLargeFile(largeFile)
        XCTAssertTrue(vm.willExecute(.myClutter))
    }

    // MARK: - Maintenance-scripts availability (periodic removed in macOS 26)

    func test_optimization_isActionableAndSelectedWhenMaintenanceAvailable() async {
        let vm = makeViewModel(maintenanceScriptsAvailable: true)
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.optimization), "Optimization seeds on when maintenance is available")
        XCTAssertTrue(vm.willExecute(.optimization))
    }

    func test_optimization_isNotActionableOrSelectedWhenMaintenanceUnavailable() async {
        let vm = makeViewModel(maintenanceScriptsAvailable: false)
        await vm.scan()
        XCTAssertFalse(vm.isModuleSelected(.optimization),
                       "Optimization must not auto-select when periodic is gone")
        XCTAssertFalse(vm.willExecute(.optimization),
                       "Optimization has no Run work when maintenance scripts are unavailable")
    }

    func test_run_skipsMaintenanceWhenUnavailableEvenIfTileSelected() async {
        var ran = false
        let vm = makeViewModel(
            maintenanceRunner: { ran = true; return "ran" },
            maintenanceScriptsAvailable: false
        )
        await vm.scan()
        // Force the tile on to prove the run-time guard, not just the seed.
        vm.toggleModule(.optimization)
        XCTAssertTrue(vm.isModuleSelected(.optimization))

        await vm.run()

        XCTAssertFalse(ran, "The removed periodic maintenance must never be invoked")
    }

    // MARK: - Scan progress count

    /// The combined "Scanned N items…" tally must sum the walked counts of the
    /// two concurrent file-walk sub-scans (System Junk + My Clutter).
    func test_scan_reportsCombinedScannedItemCountAcrossFileWalkSubScans() async {
        let vm = SmartScanViewModel(
            junkScanner: { progress in
                progress(100)
                await Task.yield()
                progress(300)
                await Task.yield()
                return ScanResult(items: [])
            },
            malwareInstalled: { false },
            malwareScanner: { _ in [] },
            loginItemsLoader: { [] },
            largeOldFilesScanner: { progress in
                progress(50)
                await Task.yield()
                progress(200)
                await Task.yield()
                return []
            },
            updatesChecker: { _ in [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        await vm.scan()
        await waitUntil { vm.scannedItemCount == 500 }

        XCTAssertEqual(
            vm.scannedItemCount,
            500,
            "Smart Scan count must sum the junk (300) and clutter (200) walk totals"
        )
    }

    /// The malware sub-scan must surface a running files-checked count so the
    /// progress readout keeps moving after the file-walk tally plateaus.
    func test_scan_reportsMalwareFilesScannedProgress() async {
        let vm = SmartScanViewModel(
            junkScanner: { _ in ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { progress in
                progress(1)
                await Task.yield()
                progress(2)
                await Task.yield()
                progress(3)
                await Task.yield()
                return []
            },
            loginItemsLoader: { [] },
            largeOldFilesScanner: { _ in [] },
            updatesChecker: { _ in [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        await vm.scan()
        await waitUntil { vm.malwareFilesScanned == 3 }

        XCTAssertEqual(
            vm.malwareFilesScanned,
            3,
            "Malware files-checked count must track the scanner's progress ticks"
        )
    }

    /// A skipped malware sub-scan (ClamAV absent) must not run the scanner nor
    /// move the files-checked count off zero.
    func test_scan_doesNotReportMalwareProgressWhenClamAVAbsent() async {
        var ranMalware = false
        let vm = SmartScanViewModel(
            junkScanner: { _ in ScanResult(items: []) },
            malwareInstalled: { false },
            malwareScanner: { progress in
                ranMalware = true
                progress(5)
                return []
            },
            loginItemsLoader: { [] },
            largeOldFilesScanner: { _ in [] },
            updatesChecker: { _ in [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        await vm.scan()

        XCTAssertFalse(ranMalware, "Malware scanner must not run when ClamAV is absent")
        XCTAssertEqual(vm.malwareFilesScanned, 0)
    }

    /// The app-update check must surface a determinate "checked of total" count
    /// so the network-bound probe shows real progress while it runs.
    func test_scan_reportsAppUpdateCheckProgress() async {
        let vm = SmartScanViewModel(
            junkScanner: { _ in ScanResult(items: []) },
            malwareInstalled: { false },
            malwareScanner: { _ in [] },
            loginItemsLoader: { [] },
            largeOldFilesScanner: { _ in [] },
            updatesChecker: { progress in
                progress(0, 4)
                await Task.yield()
                progress(2, 4)
                await Task.yield()
                progress(4, 4)
                await Task.yield()
                return []
            },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        await vm.scan()
        await waitUntil { vm.appsChecked == 4 && vm.appsTotal == 4 }

        XCTAssertEqual(vm.appsChecked, 4, "Apps-checked count must reach the total")
        XCTAssertEqual(vm.appsTotal, 4, "Apps-total must reflect the discovered app count")
    }

    /// `scanProgressDetail` must compose the file-walk, malware, and app-update
    /// signals into one status line so every active sub-scan is visible.
    func test_scanProgressDetail_composesItemsThreatsAndApps() async {
        let vm = SmartScanViewModel(
            junkScanner: { progress in
                progress(500)
                await Task.yield()
                return ScanResult(items: [])
            },
            malwareInstalled: { true },
            malwareScanner: { progress in
                progress(3)
                await Task.yield()
                return []
            },
            loginItemsLoader: { [] },
            largeOldFilesScanner: { _ in [] },
            updatesChecker: { progress in
                progress(4, 4)
                await Task.yield()
                return []
            },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        await vm.scan()
        await waitUntil {
            vm.scannedItemCount == 500 && vm.malwareFilesScanned == 3 && vm.appsTotal == 4
        }

        let detail = vm.scanProgressDetail
        XCTAssertTrue(detail.contains("500"), "Detail must include the file-walk item count: \(detail)")
        XCTAssertTrue(detail.contains("3"), "Detail must include the malware files-checked count: \(detail)")
        XCTAssertTrue(detail.contains("4"), "Detail must include the app-update progress: \(detail)")
    }

    // MARK: - Scan stage (phrase theming)

    /// While the file walks are still running, the current stage must read as
    /// the broad file-sweep so the dashboard shows the all-modules phrasing.
    func test_currentStage_isSweepingFiles_whileWalksRun() async {
        let gate = AsyncGate()
        let vm = SmartScanViewModel(
            junkScanner: { _ in await gate.wait(); return ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { _ in [] },
            loginItemsLoader: { [] },
            largeOldFilesScanner: { _ in [] },
            updatesChecker: { _ in [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        let scanTask = Task { await vm.scan() }
        await waitUntil { if case .scanning = vm.phase { return true } else { return false } }

        XCTAssertEqual(vm.currentStage, .sweepingFiles,
                       "A still-running file walk must keep the stage on the broad sweep")

        gate.open()
        await scanTask.value
    }

    /// Once the walks finish but the malware content scan is still running, the
    /// stage must switch to threats so the malware-flavored phrases show.
    func test_currentStage_isScanningThreats_whileMalwareRunsAfterWalks() async {
        let gate = AsyncGate()
        let vm = SmartScanViewModel(
            junkScanner: { _ in ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { _ in await gate.wait(); return [] },
            loginItemsLoader: { [] },
            largeOldFilesScanner: { _ in [] },
            updatesChecker: { _ in [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        let scanTask = Task { await vm.scan() }
        await waitUntil { vm.currentStage == .scanningThreats }

        XCTAssertEqual(vm.currentStage, .scanningThreats)

        gate.open()
        await scanTask.value
        XCTAssertEqual(vm.currentStage, .checkingApps,
                       "With walks and malware done, the stage rests on the app-update check")
    }

    /// With the walks and malware done, a still-running app-update probe must
    /// put the stage on the app check.
    func test_currentStage_isCheckingApps_whileUpdatesRunLast() async {
        let gate = AsyncGate()
        let vm = SmartScanViewModel(
            junkScanner: { _ in ScanResult(items: []) },
            malwareInstalled: { false },
            malwareScanner: { _ in [] },
            loginItemsLoader: { [] },
            largeOldFilesScanner: { _ in [] },
            updatesChecker: { _ in await gate.wait(); return [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        let scanTask = Task { await vm.scan() }
        await waitUntil { vm.currentStage == .checkingApps }

        XCTAssertEqual(vm.currentStage, .checkingApps)

        gate.open()
        await scanTask.value
    }

    /// Each stage must resolve to a non-empty, section-appropriate phrase set:
    /// the broad sweep reuses the Smart Scan voice, threats the Malware voice,
    /// and the app check its own dedicated voice.
    func test_smartScanStagePhrases_matchActiveSection() {
        XCTAssertEqual(
            ScanPhrases.smartScanStage(.sweepingFiles),
            ScanPhrases.scanning(for: .smartScan)
        )
        XCTAssertEqual(
            ScanPhrases.smartScanStage(.scanningThreats),
            ScanPhrases.scanning(for: .malwareRemoval)
        )
        XCTAssertFalse(
            ScanPhrases.smartScanStage(.checkingApps).isEmpty,
            "The app-update stage must have its own phrase set"
        )
    }

    // MARK: - Helpers

    private func makeViewModel(
        junkScanner: @escaping () async throws -> ScanResult = { ScanResult(items: []) },
        malwareInstalled: @escaping SmartScanViewModel.MalwareInstalled = { true },
        malwareScanner: @escaping () async -> [MalwareThreat] = { [] },
        loginItemsLoader: @escaping SmartScanViewModel.LoginItemsLoader = { [] },
        largeOldFilesScanner: @escaping () async -> [ScannedFile] = { [] },
        updatesChecker: @escaping () async -> [UpdateInfo] = { [] },
        junkCleaner: @escaping SmartScanViewModel.JunkCleaner = { _ in 0 },
        threatRemover: @escaping SmartScanViewModel.ThreatRemover = { _ in [] },
        maintenanceRunner: @escaping SmartScanViewModel.MaintenanceRunner = { "" },
        updateOpener: @escaping SmartScanViewModel.UpdateOpener = { _ in },
        largeFileDeleter: @escaping SmartScanViewModel.LargeFileDeleter = { _ in [] },
        maintenanceScriptsAvailable: Bool = true
    ) -> SmartScanViewModel {
        // Adapt the progress-free test closures to the production sub-scanner
        // signatures; the count test below constructs the VM directly to drive
        // the progress callbacks.
        SmartScanViewModel(
            junkScanner: { _ in try await junkScanner() },
            malwareInstalled: malwareInstalled,
            malwareScanner: { _ in await malwareScanner() },
            loginItemsLoader: loginItemsLoader,
            largeOldFilesScanner: { _ in await largeOldFilesScanner() },
            updatesChecker: { _ in await updatesChecker() },
            junkCleaner: junkCleaner,
            threatRemover: threatRemover,
            maintenanceRunner: maintenanceRunner,
            updateOpener: updateOpener,
            largeFileDeleter: largeFileDeleter,
            maintenanceScriptsAvailable: maintenanceScriptsAvailable
        )
    }

    private func makeResult(_ groups: (ScanCategory, [ScannedFile])...) -> ScanResult {
        ScanResult(items: groups.flatMap { $0.1 })
    }

    private func makeFile(name: String, size: Int64, category: ScanCategory) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: "/tmp/ssv-tests/\(category.rawValue)/\(name)"),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }
}

/// A one-shot async gate used to hold a fake sub-scanner suspended so a test
/// can observe the Smart Scan stage while exactly one sub-scan is still in
/// flight. `wait()` suspends until `open()` is called (or returns immediately
/// if already opened).
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let resume = continuation
        continuation = nil
        lock.unlock()
        resume?.resume()
    }
}
