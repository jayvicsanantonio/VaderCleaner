// SmartScanViewModelTests.swift
// Drives the SmartScanViewModel state machine — sequential junk/malware/login orchestration, result aggregation, and the unified clean() delegation — through injected fakes.

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

    /// A duplicate group fronting the My Clutter tile: a kept original plus one
    /// redundant copy (so `reclaimableBytes == 1000` and one copy is deletable).
    private var dupGroup: DuplicateGroup {
        DuplicateGroup(files: [
            ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/report.pdf"),
                        size: 1000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile),
            ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/report copy.pdf"),
                        size: 1000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile),
        ])
    }

    /// The redundant (deletable) copy inside `dupGroup`.
    private var dupCopy: ScannedFile { dupGroup.redundantCopies[0] }

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
        XCTAssertEqual(result.performanceItems, [loginItem])
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
        XCTAssertEqual(result.performanceItems.count, 1)
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
        XCTAssertEqual(result.performanceItems, [])
    }

    func test_scan_populatesDuplicatesFromScanner() async {
        var ranDuplicates = false
        let vm = makeViewModel(
            duplicatesScanner: {
                ranDuplicates = true
                return [self.dupGroup]
            }
        )

        await vm.scan()

        XCTAssertTrue(ranDuplicates, "Smart Scan must run the duplicate-files scan")
        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.duplicateGroups, [dupGroup])
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

    func test_scan_emptyDuplicatesAndUpdates_defaultEmpty() async {
        let vm = makeViewModel()

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertEqual(result.duplicateGroups, [])
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
        // Junk has bytes, malware has a threat, updates has one entry,
        // duplicates has one group, login items has one — every module should
        // default to checked. Performance additionally is always actionable
        // (its DNS flush always has work), so it is also on.
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 100, category: .userCache)])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            loginItemsLoader: { [self.loginItem] },
            duplicatesScanner: { [self.dupGroup] },
            updatesChecker: { [self.availableUpdate] }
        )

        await vm.scan()

        XCTAssertEqual(vm.tileSelection, Set(SmartScanModule.allCases))
    }

    func test_scan_defaultsTileSelectionExcludesModulesWithoutWork() async {
        // Junk has bytes, but every other module is empty. Performance
        // stays on because maintenance scripts are always actionable.
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 100, category: .userCache)])) }
        )

        await vm.scan()

        XCTAssertEqual(vm.tileSelection, [.systemJunk, .performance])
    }

    func test_scan_defaultsTileSelectionEmptyExceptPerformanceWhenNothingFound() async {
        let vm = makeViewModel()

        await vm.scan()

        XCTAssertEqual(vm.tileSelection, [.performance])
    }

    func test_toggleModule_addsThenRemovesFromSelection() async {
        let vm = makeViewModel()
        await vm.scan()
        // Performance is on by default.
        XCTAssertTrue(vm.isModuleSelected(.performance))

        vm.toggleModule(.performance)
        XCTAssertFalse(vm.isModuleSelected(.performance))

        vm.toggleModule(.performance)
        XCTAssertTrue(vm.isModuleSelected(.performance))
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

    func test_scan_defaultsLargeFileSelectionToRedundantCopies() async {
        // A duplicate delete always leaves one copy, so the redundant copies are
        // selected by default (matching Smart Care). The kept original is never
        // selected, so Run can't remove the last copy.
        let vm = makeViewModel(
            duplicatesScanner: { [self.dupGroup] }
        )

        await vm.scan()

        XCTAssertEqual(vm.largeFileSelection, [dupCopy.url])
        XCTAssertFalse(vm.largeFileSelection.contains(dupGroup.original.url),
                       "The kept original must never be selected for deletion")
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

    func test_scan_defaultsJunkFileSelectionToSafeCategoryFiles() async {
        let a = makeFile(name: "a", size: 1, category: .userCache)
        let b = makeFile(name: "b", size: 2, category: .userLogs)
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [a]), (.userLogs, [b])) }
        )

        await vm.scan()

        XCTAssertEqual(vm.junkFileSelection, [a.url, b.url],
                       "Cleanup Manager opens with every safe-category junk file checked")
    }

    /// The one-tap Scan→Run path must never pre-check user data: files in the
    /// risky categories (mail attachments, iOS backups) are still found and
    /// listed, but start unchecked so removing them is an explicit choice.
    func test_scan_defaultsJunkFileSelectionExcludesRiskyCategories() async {
        let safe = makeFile(name: "cache", size: 1, category: .userCache)
        let mail = makeFile(name: "att", size: 2, category: .mailAttachments)
        let backup = makeFile(name: "ios", size: 3, category: .iosBackups)
        let vm = makeViewModel(
            junkScanner: {
                self.makeResult(
                    (.userCache, [safe]),
                    (.mailAttachments, [mail]),
                    (.iosBackups, [backup])
                )
            }
        )

        await vm.scan()

        XCTAssertEqual(vm.junkFileSelection, [safe.url],
                       "Run must pre-check only safe-category files, never mail attachments or iOS backups")
        XCTAssertFalse(vm.isJunkFileSelected(mail),
                       "Mail attachments start unchecked — removing them is opt-in")
        XCTAssertFalse(vm.isJunkFileSelected(backup),
                       "iOS backups start unchecked — removing them is opt-in")
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

    // MARK: - Junk selection tallies (store-backed Cleanup Manager)

    /// The per-category byte/count tallies and the running total are seeded from
    /// the same safe-by-default selection, so the Cleanup Manager's badges are
    /// correct the instant it opens — no re-walk of the file list.
    func test_selectedJunkTallies_seededForSafeCategoriesOnly() async {
        let cacheA = makeFile(name: "a", size: 100, category: .userCache)
        let cacheB = makeFile(name: "b", size: 30, category: .userCache)
        let mail = makeFile(name: "m", size: 500, category: .mailAttachments)
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [cacheA, cacheB]), (.mailAttachments, [mail])) }
        )
        await vm.scan()

        XCTAssertEqual(vm.selectedJunkBytes(in: .userCache), 130)
        XCTAssertEqual(vm.selectedJunkCount(in: .userCache), 2)
        XCTAssertEqual(vm.selectedJunkBytes(in: .mailAttachments), 0, "Risky category isn't pre-checked")
        XCTAssertEqual(vm.selectedJunkCount(in: .mailAttachments), 0)
        XCTAssertEqual(vm.selectedJunkBytes, 130, "Running total covers only the safe files")
    }

    /// A batched folder/category write keeps the tallies in lockstep and is
    /// idempotent — re-selecting an already-selected file must not double-count.
    func test_setJunkFiles_batchedUpdateMaintainsTallies() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 30, category: .userCache)
        let vm = makeViewModel(junkScanner: { self.makeResult((.userCache, [a, b])) })
        await vm.scan()

        vm.setJunkFiles([a, b], selected: false)   // clear the folder
        XCTAssertEqual(vm.selectedJunkCount(in: .userCache), 0)
        XCTAssertEqual(vm.selectedJunkBytes, 0)

        vm.setJunkFiles([a, b], selected: true)
        vm.setJunkFiles([a, b], selected: true)    // idempotent
        XCTAssertEqual(vm.selectedJunkCount(in: .userCache), 2)
        XCTAssertEqual(vm.selectedJunkBytes, 130)
    }

    /// A folder-row toggle is all-or-nothing: a fully-selected group clears, and
    /// a partial or empty group fills in.
    func test_toggleJunkFiles_folderToggleAllOrNothing() async {
        let a = makeFile(name: "a", size: 100, category: .userCache)
        let b = makeFile(name: "b", size: 30, category: .userCache)
        let vm = makeViewModel(junkScanner: { self.makeResult((.userCache, [a, b])) })
        await vm.scan()
        XCTAssertTrue(vm.areAllJunkFilesSelected([a, b]), "Safe files start selected")

        vm.toggleJunkFiles([a, b])   // all → clear
        XCTAssertFalse(vm.areAllJunkFilesSelected([a, b]))
        XCTAssertEqual(vm.selectedJunkCount(in: .userCache), 0)

        vm.toggleJunkFiles([a, b])   // none → all
        XCTAssertTrue(vm.areAllJunkFilesSelected([a, b]))
        XCTAssertEqual(vm.selectedJunkCount(in: .userCache), 2)
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
        let vm = makeViewModel(duplicatesScanner: { [self.dupGroup] })
        await vm.scan()
        // Redundant copies default to selected.
        XCTAssertTrue(vm.isLargeFileSelected(dupCopy))

        vm.setLargeFiles([dupCopy.url], selected: false)
        XCTAssertFalse(vm.isLargeFileSelected(dupCopy))

        vm.setLargeFiles([dupCopy.url], selected: true)
        XCTAssertTrue(vm.isLargeFileSelected(dupCopy))
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

    func test_scan_preservesDuplicateGroupOrderFromScanner() async {
        // The scanner already orders groups by reclaimable bytes; the result must
        // surface them in that same order for the Review list.
        let small = DuplicateGroup(files: [
            ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/s1"), size: 1_000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile),
            ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/s2"), size: 1_000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile),
        ])
        let big = DuplicateGroup(files: [
            ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/b1"), size: 9_000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile),
            ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/b2"), size: 9_000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile),
        ])
        let vm = makeViewModel(duplicatesScanner: { [big, small] })

        await vm.scan()

        guard case .results(let result) = vm.phase else { return XCTFail("Expected .results") }
        XCTAssertEqual(result.duplicateGroups, [big, small])
    }

    func test_selectAllLargeFiles_selectsEveryRedundantCopyWithOneWrite() async {
        let vm = makeViewModel(duplicatesScanner: { [self.dupGroup] })
        await vm.scan()
        vm.clearLargeFileSelection()
        XCTAssertTrue(vm.largeFileSelection.isEmpty)

        vm.selectAllLargeFiles()

        XCTAssertEqual(vm.largeFileSelection, [dupCopy.url])
    }

    func test_selectAllLargeFiles_outsideResults_isNoop() {
        let vm = makeViewModel()
        // `.idle` — never scanned.
        vm.selectAllLargeFiles()
        XCTAssertTrue(vm.largeFileSelection.isEmpty)
    }

    func test_clearLargeFileSelection_emptiesTheSet() async {
        let vm = makeViewModel(duplicatesScanner: { [self.dupGroup] })
        await vm.scan()
        XCTAssertFalse(vm.largeFileSelection.isEmpty)

        vm.clearLargeFileSelection()

        XCTAssertTrue(vm.largeFileSelection.isEmpty)
    }

    func test_toggleLargeFile_addsAndRemoves() async {
        let vm = makeViewModel(
            duplicatesScanner: { [self.dupGroup] }
        )
        await vm.scan()
        // The redundant copy is selected by default.
        XCTAssertTrue(vm.isLargeFileSelected(dupCopy))

        vm.toggleLargeFile(dupCopy)
        XCTAssertFalse(vm.isLargeFileSelected(dupCopy))

        vm.toggleLargeFile(dupCopy)
        XCTAssertTrue(vm.isLargeFileSelected(dupCopy))
    }

    func test_reset_clearsAllSubSelections() async {
        let vm = makeViewModel(
            junkScanner: { self.makeResult((.userCache, [self.makeFile(name: "a", size: 1, category: .userCache)])) },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            duplicatesScanner: { [self.dupGroup] },
            updatesChecker: { [self.availableUpdate] }
        )
        await vm.scan()
        // The redundant copy is selected by default, so largeFileSelection is
        // already non-empty — no manual toggle needed.
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
                      "run() must NOT auto-disable login items — Performance wires the maintenance-script action, not login-item changes")
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
        // Deselect Performance so the summary line stays focused on the
        // junk/malware result for this assertion — Performance wiring is
        // covered by its own tests below.
        vm.toggleModule(.performance)

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
        vm.toggleModule(.performance)

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

    // MARK: - Run: Performance (maintenance scripts)

    func test_run_runsMaintenanceWhenPerformanceSelected() async {
        var ranMaintenance = false
        let vm = makeViewModel(
            maintenanceRunner: {
                ranMaintenance = true
                return "ran"
            }
        )
        await vm.scan()
        // Performance defaults on with maintenance.

        await vm.run()

        XCTAssertTrue(ranMaintenance)
        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.maintenanceOutput, "ran")
    }

    func test_run_skipsMaintenanceWhenPerformanceDeselected() async {
        var ranMaintenance = false
        let vm = makeViewModel(
            maintenanceRunner: {
                ranMaintenance = true
                return "ran"
            }
        )
        await vm.scan()
        vm.toggleModule(.performance)   // deselect

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
        XCTAssertTrue(summary.failedModules.contains(.performance))
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

    // MARK: - Run: My Clutter (delete selected duplicate copies)

    func test_run_deletesSelectedDuplicateCopies() async {
        var receivedURLs: [URL] = []
        let vm = makeViewModel(
            duplicatesScanner: { [self.dupGroup] },
            largeFileDeleter: { urls in
                receivedURLs = urls
                return Set(urls)
            }
        )
        await vm.scan()
        // The redundant copy is selected by default — no manual opt-in needed.

        await vm.run()

        XCTAssertEqual(receivedURLs, [dupCopy.url])
        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.clutterFilesRemoved, 1)
        XCTAssertEqual(summary.clutterBytesRemoved, dupCopy.size)
    }

    func test_run_skipsMyClutterWhenNothingSelected() async {
        // Deselecting every copy must mean the deleter is NOT called with [].
        var deleterCalls = 0
        let vm = makeViewModel(
            duplicatesScanner: { [self.dupGroup] },
            largeFileDeleter: { _ in deleterCalls += 1; return [] }
        )
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.myClutter))
        vm.clearLargeFileSelection()

        await vm.run()

        XCTAssertEqual(deleterCalls, 0)
    }

    func test_run_recordsClutterPartialSuccess() async {
        // A group with two redundant copies; the deleter removes only one.
        let original = ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/clip.mov"),
                                   size: 9_000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile)
        let copy1 = ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/clip copy.mov"),
                                size: 9_000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile)
        let copy2 = ScannedFile(url: URL(fileURLWithPath: "/Users/me/Downloads/clip locked.mov"),
                                size: 9_000, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile)
        let group = DuplicateGroup(files: [original, copy1, copy2])
        let vm = makeViewModel(
            duplicatesScanner: { [group] },
            // Deleter reports only `copy1` removed — `copy2` was locked.
            largeFileDeleter: { _ in [copy1.url] }
        )
        await vm.scan()
        // Both copies are selected by default.

        await vm.run()

        guard case .done(let summary) = vm.phase else {
            return XCTFail("Expected .done, got \(vm.phase)")
        }
        XCTAssertEqual(summary.clutterFilesRemoved, 1)
        XCTAssertEqual(summary.clutterBytesRemoved, copy1.size)
        XCTAssertTrue(summary.failedModules.contains(.myClutter))
    }

    // MARK: - Executable work surface

    func test_hasExecutableWork_falseAtIdle() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.hasExecutableWork)
    }

    func test_hasExecutableWork_trueAtResultsWithPerformanceOn() async {
        let vm = makeViewModel()
        await vm.scan()
        // Performance defaults on with always-actionable maintenance, so a
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

    // MARK: - Floating Run disc visibility

    func test_isRunDiscVisible_falseAtIdle() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.isRunDiscVisible, "No Run disc before a scan lands on results")
    }

    func test_isRunDiscVisible_trueAtResultsWithWork() async {
        let vm = makeViewModel()
        await vm.scan()
        XCTAssertTrue(vm.isRunDiscVisible, "Run disc shows on the results dashboard with executable work")
    }

    /// Opening a tile's Review Manager must hide the floating Run disc — the
    /// Manager owns the bottom bar, so an overlapping disc reads as clutter.
    func test_isRunDiscVisible_falseWhileReviewing() async {
        let vm = makeViewModel()
        await vm.scan()
        XCTAssertTrue(vm.isRunDiscVisible)

        vm.setReviewing(true)
        XCTAssertFalse(vm.isRunDiscVisible, "Run disc hides while a Review Manager is open")
        XCTAssertTrue(vm.isReviewing)

        vm.setReviewing(false)
        XCTAssertTrue(vm.isRunDiscVisible, "Run disc returns when the Review closes")
    }

    func test_reset_clearsIsReviewing() async {
        let vm = makeViewModel()
        await vm.scan()
        vm.setReviewing(true)

        vm.reset()

        XCTAssertFalse(vm.isReviewing, "A reset clears the in-flight Review flag")
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

    func test_willExecute_myClutterRequiresAtLeastOneCopySelected() async {
        let vm = makeViewModel(duplicatesScanner: { [self.dupGroup] })
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.myClutter))
        // Redundant copies default to selected, so the tile has work.
        XCTAssertTrue(vm.willExecute(.myClutter))

        vm.clearLargeFileSelection()
        XCTAssertFalse(vm.willExecute(.myClutter))
    }

    // MARK: - Maintenance-scripts availability (periodic removed in macOS 26)

    func test_performance_isActionableAndSelectedWhenMaintenanceAvailable() async {
        let vm = makeViewModel(maintenanceScriptsAvailable: true)
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.performance), "Performance seeds on when maintenance is available")
        XCTAssertTrue(vm.willExecute(.performance))
    }

    func test_performance_stillActionableAndSelectedWhenMaintenanceUnavailable() async {
        // Even without periodic (macOS 26), Performance keeps its DNS-cache
        // flush, so it must stay actionable and auto-selected — matching Smart
        // Care's Performance module (maintenance scripts + Flush DNS).
        let vm = makeViewModel(maintenanceScriptsAvailable: false)
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.performance),
                      "Performance auto-selects because the DNS flush always has work")
        XCTAssertTrue(vm.willExecute(.performance),
                      "Performance is actionable via the DNS flush even without periodic")
    }

    func test_run_skipsMaintenanceScriptsButFlushesDNSWhenScriptsUnavailable() async {
        var ranScripts = false
        var ranDNS = false
        let vm = makeViewModel(
            maintenanceRunner: { ranScripts = true; return "scripts" },
            dnsFlusher: { ranDNS = true; return "flushed DNS" },
            maintenanceScriptsAvailable: false
        )
        await vm.scan()
        XCTAssertTrue(vm.isModuleSelected(.performance))

        await vm.run()

        XCTAssertFalse(ranScripts, "The removed periodic maintenance must never be invoked")
        XCTAssertTrue(ranDNS, "The DNS flush must still run — it needs no periodic")
    }

    func test_run_flushesDNSAndRunsScriptsWhenPerformanceSelected() async {
        var ranScripts = false
        var ranDNS = false
        let vm = makeViewModel(
            maintenanceRunner: { ranScripts = true; return "ran scripts" },
            dnsFlusher: { ranDNS = true; return "flushed DNS" },
            maintenanceScriptsAvailable: true
        )
        await vm.scan()

        await vm.run()

        XCTAssertTrue(ranScripts && ranDNS, "Performance runs both maintenance scripts and the DNS flush")
        guard case .done(let summary) = vm.phase else { return XCTFail("Expected .done") }
        let output = summary.maintenanceOutput ?? ""
        XCTAssertTrue(output.contains("ran scripts"), "Summary must include the maintenance-scripts line")
        XCTAssertTrue(output.contains("flushed DNS"), "Summary must include the DNS-flush line")
    }

    // MARK: - Sequential execution

    /// The five sub-scans must run one at a time, in `scanCollectionOrder`: a
    /// later sub-scan must not start until the current one has fully finished,
    /// and the start order must match the collection order.
    func test_scan_runsSubScansSequentially() async {
        let gate = AsyncGate()
        let recorder = StartRecorder()
        let vm = SmartScanViewModel(
            junkScanner: { _ in
                recorder.record("systemJunk")
                await gate.wait()
                return ScanResult(items: [])
            },
            malwareInstalled: { true },
            malwareScanner: { _ in recorder.record("malware"); return [] },
            loginItemsLoader: { recorder.record("performance"); return [] },
            duplicatesScanner: { _ in recorder.record("myClutter"); return [] },
            updatesChecker: { _ in recorder.record("applications"); return [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] }
        )

        let scanTask = Task { await vm.scan() }
        // Wait until the first sub-scan has started and parked on the gate.
        await waitUntil { recorder.all == ["systemJunk"] }
        // Give the runtime several turns to (wrongly) start other sub-scans if
        // they were still running concurrently; the gate keeps the first parked.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            recorder.all, ["systemJunk"],
            "No later sub-scan may start while the first is still running"
        )

        gate.open()
        await scanTask.value
        XCTAssertEqual(
            recorder.all,
            ["systemJunk", "myClutter", "performance", "malware", "applications"],
            "Sub-scans must start one at a time in collection order"
        )
    }

    /// Each module's sub-scan must be preceded by a hero-settle await, so
    /// scanning only begins once the module has taken the hero slot.
    func test_scan_settlesHeroBeforeEachModuleScan() async {
        let events = StartRecorder()
        let vm = SmartScanViewModel(
            junkScanner: { _ in events.record("scan:systemJunk"); return ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { _ in events.record("scan:malware"); return [] },
            loginItemsLoader: { events.record("scan:performance"); return [] },
            duplicatesScanner: { _ in events.record("scan:myClutter"); return [] },
            updatesChecker: { _ in events.record("scan:applications"); return [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] },
            heroSettle: { events.record("settle") }
        )

        await vm.scan()

        XCTAssertEqual(
            events.all,
            [
                "settle", "scan:systemJunk",
                "settle", "scan:myClutter",
                "settle", "scan:performance",
                "settle", "scan:malware",
                "settle", "scan:applications",
            ],
            "Every module's scan must be immediately preceded by a hero settle"
        )
    }

    /// A skipped module (disabled) is never the hero, so it must not trigger a
    /// hero-settle pause — only the modules that actually take the hero wait.
    func test_scan_doesNotSettleForSkippedModule() async {
        let events = StartRecorder()
        let vm = SmartScanViewModel(
            junkScanner: { _ in events.record("scan:systemJunk"); return ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { _ in events.record("scan:malware"); return [] },
            loginItemsLoader: { events.record("scan:performance"); return [] },
            duplicatesScanner: { _ in events.record("scan:myClutter"); return [] },
            updatesChecker: { _ in events.record("scan:applications"); return [] },
            junkCleaner: { _ in 0 },
            threatRemover: { _ in [] },
            maintenanceRunner: { "" },
            updateOpener: { _ in },
            largeFileDeleter: { _ in [] },
            heroSettle: { events.record("settle") },
            // My Clutter is excluded from this run, so it never takes the hero.
            enabledModules: { [.systemJunk, .performance, .malware, .applications] }
        )

        await vm.scan()

        XCTAssertFalse(
            events.all.contains("scan:myClutter"),
            "A disabled module's sub-scan must not run"
        )
        XCTAssertEqual(
            events.all.filter { $0 == "settle" }.count, 4,
            "Only the four modules that take the hero may trigger a settle"
        )
    }

    // MARK: - Scan progress count

    /// The combined "Scanned N items…" tally must sum the walked counts of the
    /// two file-walk sub-scans (System Junk + My Clutter).
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
            duplicatesScanner: { progress in
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
            duplicatesScanner: { _ in [] },
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
            duplicatesScanner: { _ in [] },
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
            duplicatesScanner: { _ in [] },
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
            duplicatesScanner: { _ in [] },
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
            duplicatesScanner: { _ in [] },
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
            duplicatesScanner: { _ in [] },
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
            duplicatesScanner: { _ in [] },
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

    // MARK: - Customize Smart Care: module gating

    func test_scan_skipsDisabledModuleSubScan() async {
        var ranJunk = false
        var ranMalware = false
        var ranLogin = false
        var ranLarge = false
        var ranUpdates = false
        let vm = makeViewModel(
            junkScanner: { ranJunk = true; return ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { ranMalware = true; return [self.threat] },
            loginItemsLoader: { ranLogin = true; return [self.loginItem] },
            duplicatesScanner: { ranLarge = true; return [self.dupGroup] },
            updatesChecker: { ranUpdates = true; return [self.availableUpdate] },
            // Everything off except System Junk.
            enabledModules: { [.systemJunk] }
        )

        await vm.scan()

        XCTAssertTrue(ranJunk, "The enabled System Junk scan must still run")
        XCTAssertFalse(ranMalware, "A disabled Malware module must not run its scan")
        XCTAssertFalse(ranLogin, "A disabled Performance module must not read login items")
        XCTAssertFalse(ranLarge, "A disabled My Clutter module must not run its scan")
        XCTAssertFalse(ranUpdates, "A disabled Applications module must not run its check")
    }

    func test_scan_disabledModuleIsAbsentFromResultsAndSelection() async {
        let junk = makeResult((.userCache, [makeFile(name: "a", size: 100, category: .userCache)]))
        let vm = makeViewModel(
            junkScanner: { junk },
            malwareInstalled: { true },
            malwareScanner: { [self.threat] },
            duplicatesScanner: { [self.dupGroup] },
            updatesChecker: { [self.availableUpdate] },
            // Malware off; everything else on.
            enabledModules: { Set(SmartScanModule.allCases).subtracting([.malware]) }
        )

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertTrue(result.threats.isEmpty, "Disabled Malware module must contribute no threats")
        XCTAssertFalse(vm.isModuleSelected(.malware), "Disabled module must not auto-select")
        XCTAssertTrue(vm.isModuleSelected(.myClutter), "An enabled module with work stays selected")
    }

    func test_scan_disabledPerformanceIsNotAutoSelected() async {
        // Performance auto-selects whenever maintenance scripts exist; disabling
        // the module must override that so the tile never comes back checked.
        let vm = makeViewModel(
            maintenanceScriptsAvailable: true,
            enabledModules: { Set(SmartScanModule.allCases).subtracting([.performance]) }
        )

        await vm.scan()

        XCTAssertFalse(vm.isModuleSelected(.performance))
    }

    // MARK: - Customize Smart Care: System Junk category gating

    func test_scan_filtersOutDisabledJunkCategories() async {
        let junk = makeResult(
            (.userCache, [makeFile(name: "keep", size: 100, category: .userCache)]),
            (.trash, [makeFile(name: "drop", size: 250, category: .trash)])
        )
        let vm = makeViewModel(
            junkScanner: { junk },
            // Trash excluded from the System Junk sub-tree.
            enabledJunkCategories: { Set(SmartScanSettingsStore.junkCategories).subtracting([.trash]) }
        )

        await vm.scan()

        guard case .results(let result) = vm.phase else {
            return XCTFail("Expected .results, got \(vm.phase)")
        }
        XCTAssertNil(result.junkResult.itemsByCategory[.trash], "Disabled category must be filtered out")
        XCTAssertNotNil(result.junkResult.itemsByCategory[.userCache], "Enabled category must remain")
        XCTAssertEqual(result.junkResult.totalSize, 100, "Only the kept category's bytes count")
    }

    func test_scan_defaultSettings_runEveryModule() async {
        // The default providers (all-on) must preserve the pre-feature behavior.
        var ranJunk = false
        var ranMalware = false
        var ranLogin = false
        var ranLarge = false
        var ranUpdates = false
        let vm = makeViewModel(
            junkScanner: { ranJunk = true; return ScanResult(items: []) },
            malwareInstalled: { true },
            malwareScanner: { ranMalware = true; return [] },
            loginItemsLoader: { ranLogin = true; return [] },
            duplicatesScanner: { ranLarge = true; return [] },
            updatesChecker: { ranUpdates = true; return [] }
        )

        await vm.scan()

        XCTAssertTrue(ranJunk && ranMalware && ranLogin && ranLarge && ranUpdates,
                      "With default (all-on) settings every sub-scan must run")
    }

    // MARK: - Helpers

    // MARK: - Staged scanning states

    func test_startingModuleStates_runsTheFirstModuleAndQueuesTheRest() {
        let states = SmartScanViewModel.startingModuleStates(
            enabled: Set(SmartScanModule.allCases),
            clamAVAvailable: true
        )
        XCTAssertEqual(states[.systemJunk], .running)
        XCTAssertEqual(states[.myClutter], .pending)
        XCTAssertEqual(states[.performance], .pending)
        XCTAssertEqual(states[.malware], .pending)
        XCTAssertEqual(states[.applications], .pending)
    }

    func test_startingModuleStates_skipsDisabledModulesAndMissingClamAV() {
        let states = SmartScanViewModel.startingModuleStates(
            enabled: [.malware, .performance],
            clamAVAvailable: false
        )
        XCTAssertEqual(states[.systemJunk], .skipped)
        XCTAssertEqual(states[.myClutter], .skipped)
        // Malware is enabled but ClamAV is absent, so its sub-scan never runs.
        XCTAssertEqual(states[.malware], .skipped)
        // The first module that will actually run takes the hero slot.
        XCTAssertEqual(states[.performance], .running)
    }

    func test_finishing_recordsTheSummaryAndPromotesTheNextPendingModule() {
        var states = SmartScanViewModel.startingModuleStates(
            enabled: Set(SmartScanModule.allCases),
            clamAVAvailable: true
        )
        states = SmartScanViewModel.finishing(
            .systemJunk, in: states, metric: "1.5 GB of junk", caption: "to clean"
        )
        XCTAssertEqual(states[.systemJunk], .finished(metric: "1.5 GB of junk", caption: "to clean"))
        XCTAssertEqual(states[.myClutter], .running)
        XCTAssertEqual(states[.performance], .pending)
    }

    func test_finishing_promotionSkipsOverSkippedModules() {
        var states = SmartScanViewModel.startingModuleStates(
            enabled: Set(SmartScanModule.allCases).subtracting([.myClutter, .performance]),
            clamAVAvailable: true
        )
        states = SmartScanViewModel.finishing(
            .systemJunk, in: states, metric: "No junk", caption: "to clean"
        )
        // My Clutter and Performance are skipped, so Malware runs next.
        XCTAssertEqual(states[.myClutter], .skipped)
        XCTAssertEqual(states[.performance], .skipped)
        XCTAssertEqual(states[.malware], .running)
    }

    func test_finishing_aSkippedModulesCollectionPointChangesNothing() {
        let states = SmartScanViewModel.startingModuleStates(
            enabled: Set(SmartScanModule.allCases).subtracting([.myClutter]),
            clamAVAvailable: true
        )
        let after = SmartScanViewModel.finishing(
            .myClutter, in: states, metric: "No duplicates", caption: "to review"
        )
        XCTAssertEqual(after, states)
    }

    func test_scan_finishesEveryModuleWithItsSummary() async {
        let junkFile = makeFile(name: "cache.db", size: 1_500_000_000, category: .userCache)
        let vm = makeViewModel(
            junkScanner: { [junkFile] in ScanResult(items: [junkFile]) },
            malwareScanner: { [] },
            loginItemsLoader: {
                [LoginItem(id: "com.example.helper", name: "Helper", isEnabled: true)]
            },
            duplicatesScanner: { [] },
            updatesChecker: { [] }
        )

        await vm.scan()

        guard case .finished(let junkMetric, let junkCaption) = vm.moduleScanStates[.systemJunk] else {
            return XCTFail("System Junk should finish with a summary")
        }
        XCTAssertTrue(junkMetric.hasSuffix("of junk"), "got \(junkMetric)")
        XCTAssertEqual(junkCaption, "to clean")
        XCTAssertEqual(vm.moduleScanStates[.malware], .finished(metric: "No threats", caption: "to remove"))
        XCTAssertEqual(vm.moduleScanStates[.performance], .finished(metric: "1 item", caption: "to review"))
        XCTAssertEqual(vm.moduleScanStates[.applications], .finished(metric: "No vital updates", caption: "to install"))
        XCTAssertEqual(vm.moduleScanStates[.myClutter], .finished(metric: "No duplicates", caption: "to review"))
        // Nothing is left running once the results are in.
        XCTAssertNil(vm.activeScanModule)
    }

    // MARK: - Factory helpers

    private func makeViewModel(
        junkScanner: @escaping () async throws -> ScanResult = { ScanResult(items: []) },
        malwareInstalled: @escaping SmartScanViewModel.MalwareInstalled = { true },
        malwareScanner: @escaping () async -> [MalwareThreat] = { [] },
        loginItemsLoader: @escaping SmartScanViewModel.LoginItemsLoader = { [] },
        duplicatesScanner: @escaping () async -> [DuplicateGroup] = { [] },
        updatesChecker: @escaping () async -> [UpdateInfo] = { [] },
        junkCleaner: @escaping SmartScanViewModel.JunkCleaner = { _ in 0 },
        threatRemover: @escaping SmartScanViewModel.ThreatRemover = { _ in [] },
        maintenanceRunner: @escaping SmartScanViewModel.MaintenanceRunner = { "" },
        dnsFlusher: @escaping SmartScanViewModel.MaintenanceRunner = { "" },
        updateOpener: @escaping SmartScanViewModel.UpdateOpener = { _ in },
        largeFileDeleter: @escaping SmartScanViewModel.LargeFileDeleter = { _ in [] },
        maintenanceScriptsAvailable: Bool = true,
        enabledModules: @escaping () -> Set<SmartScanModule> = { Set(SmartScanModule.allCases) },
        enabledJunkCategories: @escaping () -> Set<ScanCategory> = { Set(SmartScanSettingsStore.junkCategories) }
    ) -> SmartScanViewModel {
        // Adapt the progress-free test closures to the production sub-scanner
        // signatures; the count test below constructs the VM directly to drive
        // the progress callbacks.
        SmartScanViewModel(
            junkScanner: { _ in try await junkScanner() },
            malwareInstalled: malwareInstalled,
            malwareScanner: { _ in await malwareScanner() },
            loginItemsLoader: loginItemsLoader,
            duplicatesScanner: { _ in await duplicatesScanner() },
            updatesChecker: { _ in await updatesChecker() },
            junkCleaner: junkCleaner,
            threatRemover: threatRemover,
            maintenanceRunner: maintenanceRunner,
            dnsFlusher: dnsFlusher,
            updateOpener: updateOpener,
            largeFileDeleter: largeFileDeleter,
            maintenanceScriptsAvailable: maintenanceScriptsAvailable,
            enabledModules: enabledModules,
            enabledJunkCategories: enabledJunkCategories
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

/// Records, in order, the name each fake sub-scan reports as it starts, so a
/// test can assert the sub-scans run one at a time in collection order. The
/// sub-scan closures run off the main actor, so the append is lock-guarded.
private final class StartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []

    func record(_ name: String) {
        lock.lock()
        started.append(name)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}
