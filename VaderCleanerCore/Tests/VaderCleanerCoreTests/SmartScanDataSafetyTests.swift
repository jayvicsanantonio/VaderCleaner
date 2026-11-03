// SmartScanDataSafetyTests.swift
// Pins what a Run may and may not do to the user's data: what stays out of the one-tap seed, whose decisions survive a re-check, what overlapping findings do to each other, and what Done can overwrite.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite struct SmartScanDataSafetyTests {

    // MARK: - Fixtures

    private nonisolated static func file(
        _ path: String,
        size: Int64 = 1_000,
        category: ScanCategory = .userCache
    ) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }

    private nonisolated static func plan(
        _ findings: [CareFinding],
        _ outcomes: [CareScanUnit: CareUnitOutcome] = [.systemJunk: .completed]
    ) -> CarePlan {
        CarePlan(
            findings: findings,
            health: nil,
            unitOutcomes: outcomes,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
    }

    private nonisolated static func app(_ name: String, at folder: String = "/Applications") -> AppInfo {
        AppInfo(
            name: name,
            bundleID: "com.example.\(name.lowercased())",
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "\(folder)/\(name).app"),
            isAppStore: false
        )
    }

    private nonisolated static func update(for app: AppInfo, url: String? = "https://example.com/update.dmg") -> UpdateInfo {
        UpdateInfo(
            appName: app.name,
            bundleID: app.bundleID,
            bundleURL: app.bundleURL,
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: .sparkle,
            updateURL: url.flatMap(URL.init(string:))
        )
    }

    /// Answers `first`, then `second` for every later scan — a full scan followed
    /// by the targeted re-check Done runs.
    private func viewModel(
        first: CarePlan,
        second: CarePlan,
        recycleFiles: @escaping SmartScanViewModel.RecycleFiles = { Set($0) }
    ) -> SmartScanViewModel {
        let count = TestBox(0)
        return SmartScanViewModel(
            scanEngine: { _, _ in
                count.value += 1
                return count.value == 1 ? first : second
            },
            recycleFiles: recycleFiles
        )
    }

    // MARK: - The one-tap seed

    /// A Fix that empties the Trash would permanently destroy what an earlier
    /// receipt promised could be restored, so the Trash is only ever an explicit
    /// choice in Review.
    @Test func theTrashIsNotPreChecked() async {
        let cache = Self.file("/cache/a")
        let trashed = Self.file("/Users/me/.Trash/tax-return.pdf", category: .trash)
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.plan([CareFinding(payload: .junk(ScanResult(items: [cache, trashed])))]) }
        )

        await vm.scan()

        #expect(vm.junkFileSelection == [cache.url])
        #expect(vm.selectedJunkCount(in: .trash) == 0)
        #expect(vm.selectedJunkBytes == 1_000)
    }

    // MARK: - Decisions survive the re-check

    @Test func aDeclinedDuplicateStaysDeclinedAfterDone() async {
        let kept = Self.file("/Downloads/a.bin")
        let declined = Self.file("/Downloads/b.bin")
        let taken = Self.file("/Downloads/c.bin")
        let vm = viewModel(
            first: Self.plan([CareFinding(payload: .duplicates([DuplicateGroup(files: [kept, declined, taken])]))]),
            second: Self.plan([CareFinding(payload: .duplicates([DuplicateGroup(files: [kept, declined])]))])
        )

        await vm.scan()
        vm.toggleDuplicate(declined)
        await vm.run()
        await vm.rescanHandledFindings()

        #expect(!vm.isDuplicateSelected(declined), "the next Fix would trash the copy the user kept")
    }

    @Test func aCopyTheRecheckNewlyFoundIsStillSeeded() async {
        let kept = Self.file("/Downloads/a.bin")
        let taken = Self.file("/Downloads/b.bin")
        let fresh = Self.file("/Downloads/c.bin")
        let vm = viewModel(
            first: Self.plan([CareFinding(payload: .duplicates([DuplicateGroup(files: [kept, taken])]))]),
            second: Self.plan([CareFinding(payload: .duplicates([DuplicateGroup(files: [kept, fresh])]))])
        )

        await vm.scan()
        await vm.run()
        await vm.rescanHandledFindings()

        #expect(vm.isDuplicateSelected(fresh))
    }

    @Test func aDeclinedThreatStaysDeclinedAfterDone() async {
        let falsePositive = MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/tool.bin"), threatName: "A")
        let real = MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/evil.bin"), threatName: "B")
        let vm = viewModel(
            first: Self.plan([CareFinding(payload: .threats([falsePositive, real]))]),
            second: Self.plan([CareFinding(payload: .threats([falsePositive]))])
        )

        await vm.scan()
        vm.toggleThreat(falsePositive)
        await vm.run()
        await vm.rescanHandledFindings()

        #expect(!vm.isThreatSelected(falsePositive))
    }

    @Test func aDeclinedUpdateStaysDeclinedAfterDone() async {
        let skipped = Self.update(for: Self.app("Skipped"))
        let taken = Self.update(for: Self.app("Taken"))
        let vm = viewModel(
            first: Self.plan([CareFinding(payload: .appUpdates([skipped, taken]))]),
            second: Self.plan([CareFinding(payload: .appUpdates([skipped, taken]))])
        )

        await vm.scan()
        vm.toggleUpdate(skipped)
        await vm.run()
        await vm.rescanHandledFindings()

        #expect(!vm.isUpdateSelected(skipped))
    }

    @Test func aDeclinedMaintenanceTaskStaysDeclinedAfterDone() async {
        let vm = viewModel(
            first: Self.plan([CareFinding(payload: .maintenanceDue(taskIDs: ["skip", "take"]))]),
            second: Self.plan([CareFinding(payload: .maintenanceDue(taskIDs: ["skip"]))])
        )

        await vm.scan()
        vm.toggleMaintenanceTask("skip")
        await vm.run()
        await vm.rescanHandledFindings()

        #expect(!vm.isMaintenanceTaskSelected("skip"))
    }

    @Test func declinedJunkStaysDeclinedWithTalliesToMatch() async {
        let declined = Self.file("/cache/keep", size: 700)
        let taken = Self.file("/cache/take", size: 300)
        let vm = viewModel(
            first: Self.plan([CareFinding(payload: .junk(ScanResult(items: [declined, taken])))]),
            second: Self.plan([CareFinding(payload: .junk(ScanResult(items: [declined, Self.file("/cache/new", size: 50)])))])
        )

        await vm.scan()
        vm.setJunkFiles([declined], selected: false)
        await vm.run()
        await vm.rescanHandledFindings()

        #expect(vm.junkFileSelection == [URL(fileURLWithPath: "/cache/new")])
        #expect(vm.selectedJunkBytes == 50)
        #expect(vm.selectedJunkCount(in: .userCache) == 1)
    }

    // MARK: - Done can't overwrite what came after it

    /// Scan → Run → Done, holding the re-check's landing in its junk seed while
    /// `window` runs: the gap where a click or a SwiftUI render would land.
    private func runWindowDuringLanding(
        lastPlan: CarePlan = Self.plan([]),
        releaseLastScan: TestBox<Bool> = TestBox(true),
        window: @MainActor (SmartScanViewModel) async -> Void
    ) async -> SmartScanViewModel {
        let scans = TestBox(0)
        let seeds = TestBox(0)
        let gate = SuspendingCallGate()
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in
                scans.value += 1
                switch scans.value {
                case 1:
                    return Self.plan([CareFinding(payload: .junk(ScanResult(items: [Self.file("/cache/first")])))])
                case 2:
                    return Self.plan([CareFinding(payload: .junk(ScanResult(items: [Self.file("/cache/found")])))])
                default:
                    while !releaseLastScan.value { try? await Task.sleep(for: .milliseconds(5)) }
                    return lastPlan
                }
            }
        )
        vm.seedJunkSelection = { result, declined in
            seeds.value += 1
            if seeds.value == 2 { await gate.hold() }
            return await ScanSelectionSeed.oneTapDefaults(from: result, excluding: declined)
        }
        await vm.scan()
        await vm.run()
        let refresh = Task { await vm.rescanHandledFindings() }
        #expect(await pollUntil { gate.isHolding })
        await window(vm)
        gate.open()
        await refresh.value
        return vm
    }

    @Test func startOverDuringTheLandingSticks() async {
        let vm = await runWindowDuringLanding { $0.reset() }
        #expect(vm.phaseID == "idle")
        #expect(vm.junkFileSelection.isEmpty)
    }

    @Test func aFreshScanDuringTheLandingKeepsItsOwnResults() async {
        let release = TestBox(false)
        let lastPlan = Self.plan([CareFinding(payload: .maintenanceDue(taskIDs: ["fresh"]))])
        let scan = TestBox<Task<Void, Never>?>(nil)
        let vm = await runWindowDuringLanding(lastPlan: lastPlan, releaseLastScan: release) { vm in
            vm.reset()
            scan.value = Task { await vm.scan() }
            #expect(await pollUntil { vm.phaseID == "scanning" })
        }
        #expect(vm.phaseID == "scanning", "the old landing must not overwrite the fresh scan")

        release.value = true
        await scan.value?.value
        #expect(vm.currentPlan?.finding(.maintenanceDue) != nil, "the fresh scan's own plan lands")
    }

    /// The re-check isn't over until the plan is whole, so Fix can't run against
    /// the partial feed while the landing is still seeding.
    @Test func fixStaysHeldBackUntilTheLandingFinishes() async {
        let heldBack = TestBox(false)
        let vm = await runWindowDuringLanding { heldBack.value = $0.isRefreshingFindings }
        #expect(heldBack.value)
        #expect(!vm.isRefreshingFindings)
    }

    /// A render during the seed reads the feed. What it caches must not outlive
    /// the partial plan, or the re-found cards never come back.
    @Test func cardsFoundByTheRecheckReachTheFeed() async {
        let vm = await runWindowDuringLanding { _ = $0.rankedFindings }
        #expect(vm.rankedFindings.contains { $0.kind == .junkCleanup })
    }

    // MARK: - Overlapping findings

    private nonisolated static let keptOriginal = file("/Downloads/kept.dmg", size: 5_000, category: .largeFile)
    private nonisolated static let sharedCopy = file("/Downloads/copy.dmg", size: 5_000, category: .largeFile)

    /// Duplicates and Downloads walk the same folder, so one file can be on both.
    private nonisolated static var overlappingPlan: CarePlan {
        plan([
            CareFinding(payload: .duplicates([DuplicateGroup(files: [keptOriginal, sharedCopy])])),
            CareFinding(payload: .downloads([
                DownloadItem(file: keptOriginal, sourceApp: nil),
                DownloadItem(file: sharedCopy, sourceApp: nil),
            ])),
        ])
    }

    /// `NSWorkspace.recycle` leaves out a URL it can't find, which is what a
    /// second finding's attempt at an already-moved file looks like.
    private nonisolated static func trashRecycler(_ trashed: TestBox<Set<URL>>) -> SmartScanViewModel.RecycleFiles {
        { urls in
            let moved = Set(urls).subtracting(trashed.value)
            trashed.value.formUnion(moved)
            return moved
        }
    }

    /// The disc says "Frees" and the hero "can be freed", and the Trash frees
    /// nothing until it's emptied, so neither counts what is only going there.
    @Test func whatOnlyGoesToTheTrashIsNotCountedAsFreed() async {
        let userCache = Self.file("/Users/me/Library/Caches/a", size: 700, category: .userCache)
        let systemCache = Self.file("/Library/Caches/b", size: 300, category: .systemCache)
        let vm = SmartScanViewModel(scanEngine: { _, _ in
            Self.plan(Self.overlappingPlan.findings + [CareFinding(payload: .junk(ScanResult(items: [userCache, systemCache])))])
        })
        await vm.scan()
        vm.setDownloads([Self.sharedCopy.url], selected: true)

        #expect(vm.freeableBytes == 300)
        #expect(vm.preApprovedFreeableBytes == 300)
        #expect(vm.freeableBytes(for: .duplicates) == 5_000, "the card still shows what is selected")
    }

    @Test func aFileOnTwoCardsIsNotReportedAsAFailure() async {
        let trashed = TestBox<Set<URL>>([])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.overlappingPlan },
            recycleFiles: Self.trashRecycler(trashed)
        )
        await vm.scan()
        vm.setDownloads([Self.sharedCopy.url], selected: true)
        await vm.run()

        guard case .done(let receipt) = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
        for line in receipt.lines {
            #expect(line.outcome == .success, "\(line.kind) reported \(line.outcome) for a file that moved")
        }
    }

    /// Picking a kept original in Downloads must not also lose its only copy to
    /// the pre-checked Duplicates card.
    @Test func removingTheKeptOriginalElsewhereKeepsACopy() async {
        let trashed = TestBox<Set<URL>>([])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.overlappingPlan },
            recycleFiles: Self.trashRecycler(trashed)
        )
        await vm.scan()
        vm.setDownloads([Self.keptOriginal.url], selected: true)
        await vm.run()

        #expect(trashed.value == [Self.keptOriginal.url], "one copy of the bytes has to survive")
    }

    /// Choosing every copy by hand is the user's explicit call.
    @Test func choosingEveryCopyByHandRemovesThemAll() async {
        let trashed = TestBox<Set<URL>>([])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.overlappingPlan },
            recycleFiles: Self.trashRecycler(trashed)
        )
        await vm.scan()
        vm.setDownloads([Self.keptOriginal.url, Self.sharedCopy.url], selected: true)
        await vm.run()

        #expect(trashed.value == [Self.keptOriginal.url, Self.sharedCopy.url])
    }

    /// A card the pass didn't re-scan loses the files the pass removed, while the
    /// user's other choices on it stand.
    @Test func cardsTheRunDidNotRescanDropWhatItRemoved() async {
        let other = Self.file("/Downloads/other.zip", size: 2_000, category: .largeFile)
        let found = Self.plan([
            CareFinding(payload: .duplicates([DuplicateGroup(files: [Self.keptOriginal, Self.sharedCopy])])),
            CareFinding(payload: .largeOldFiles([Self.sharedCopy, other])),
        ])
        let vm = viewModel(first: found, second: Self.plan([], [.duplicates: .completed]))

        await vm.scan()
        // Chosen and then left out of this pass, so the choice has to survive it.
        vm.setLargeOldFiles([other.url], selected: true)
        vm.setFindingIncluded(.largeOldFiles, false)
        await vm.run()
        await vm.rescanHandledFindings()

        guard case .largeOldFiles(let files)? = vm.currentPlan?.finding(.largeOldFiles)?.payload else {
            Issue.record("the untouched file should keep its card")
            return
        }
        #expect(files.map(\.url) == [other.url])
        #expect(vm.isLargeOldFileSelected(other))
    }

    /// An app the pass uninstalled can't keep a pre-checked update.
    @Test func anUninstalledAppLeavesTheOtherAppCards() async {
        let stale = Self.app("Stale")
        let unused = UnusedApp(app: stale, lastUsedDate: .distantPast, sizeBytes: 1_000)
        let found = Self.plan([
            CareFinding(payload: .unusedApps([unused])),
            CareFinding(payload: .appUpdates([Self.update(for: stale)])),
            CareFinding(payload: .unsupportedApps([UnsupportedApp(app: stale, reason: .incompatibleArchitecture)])),
        ])
        let vm = viewModel(first: found, second: Self.plan([], [.unusedApps: .completed]))

        await vm.scan()
        vm.setUnusedApps([unused.id], selected: true)
        vm.setFindingIncluded(.appUpdates, false)
        await vm.run()
        await vm.rescanHandledFindings()

        #expect(vm.currentPlan?.finding(.appUpdates) == nil)
        #expect(vm.currentPlan?.finding(.unsupportedApps) == nil)
        #expect(vm.selectionCount(for: .appUpdates) == 0)
    }

    // MARK: - Uninstalling an unused app

    /// Refused by the Trash means still installed, and an installed app keeps its
    /// preferences.
    @Test func aBundleThatWontMoveKeepsItsSupportFiles() async {
        let bundle = Self.app("Stale").bundleURL
        let support = URL(fileURLWithPath: "/Users/me/Library/Preferences/com.example.stale.plist")
        let unused = UnusedApp(app: Self.app("Stale"), lastUsedDate: .distantPast, sizeBytes: 1_000)
        let trashed = TestBox<Set<URL>>([])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.plan([CareFinding(payload: .unusedApps([unused]))]) },
            recycleFiles: { urls in
                let moved = Set(urls).subtracting([bundle])
                trashed.value.formUnion(moved)
                return moved
            },
            findAssociatedFiles: { _ in [AssociatedFile(url: support, sizeBytes: 10, category: .preferences)] }
        )

        await vm.scan()
        vm.setUnusedApps([unused.id], selected: true)
        await vm.run()

        #expect(trashed.value.isEmpty)
    }

    // MARK: - Opening updates

    /// The feed is the app's own, not ours, and the card is pre-checked. Only
    /// https may reach `NSWorkspace.open`, the rule the Updater already holds its
    /// own downloads to.
    @Test(arguments: ["file:///Applications/Calculator.app", "http://example.com/a.dmg", "x-custom://do-something"])
    func onlyHTTPSUpdateLinksAreOpened(link: String) async {
        let opened = TestBox<[URL]>([])
        let safe = Self.update(for: Self.app("Safe"))
        let unsafe = Self.update(for: Self.app("Unsafe"), url: link)
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.plan([CareFinding(payload: .appUpdates([safe, unsafe]))]) },
            updateOpener: { opened.value.append($0) }
        )

        await vm.scan()
        await vm.run()

        #expect(opened.value == [safe.updateURL])
        guard case .done(let receipt) = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
        #expect(receipt.lines.first?.itemsProcessed == 1)
        #expect(receipt.lines.first?.outcome == .partial(failedCount: 1))
    }

    // MARK: - Uninstalling: running apps and other copies

    private func uninstallRun(
        selecting apps: [UnusedApp],
        running: Set<String> = [],
        installed: @escaping SmartScanViewModel.InstalledApps,
        trashed: TestBox<Set<URL>>
    ) async -> SmartScanViewModel {
        let support = URL(fileURLWithPath: "/Users/me/Library/Preferences/com.example.stale.plist")
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.plan([CareFinding(payload: .unusedApps(apps))]) },
            recycleFiles: { urls in
                trashed.value.formUnion(urls)
                return Set(urls)
            },
            findAssociatedFiles: { _ in [AssociatedFile(url: support, sizeBytes: 10, category: .preferences)] },
            appIsRunning: { running.contains($0.id) },
            installedApps: installed
        )
        await vm.scan()
        vm.setUnusedApps(apps.map(\.id), selected: true)
        await vm.run()
        return vm
    }

    private nonisolated static let supportFile = URL(fileURLWithPath: "/Users/me/Library/Preferences/com.example.stale.plist")

    @Test func aRunningAppIsNotAttempted() async {
        let stale = Self.app("Stale")
        let trashed = TestBox<Set<URL>>([])
        let vm = await uninstallRun(
            selecting: [UnusedApp(app: stale, lastUsedDate: .distantPast, sizeBytes: 1_000)],
            running: [stale.id],
            installed: { [stale] },
            trashed: trashed
        )

        #expect(trashed.value.isEmpty)
        guard case .done(let receipt) = vm.phase else {
            Issue.record("expected .done, got \(vm.phase)")
            return
        }
        #expect(receipt.lines.first?.outcome == .partial(failedCount: 1))
    }

    /// Support files are named for the bundle ID, so an old copy's uninstall can't
    /// take the settings of the copy still in use.
    @Test func anotherInstalledCopyKeepsTheSupportFiles() async {
        let staleCopy = Self.app("Stale", at: "/Users/me/Applications")
        let inUse = Self.app("Stale")
        let trashed = TestBox<Set<URL>>([])
        _ = await uninstallRun(
            selecting: [UnusedApp(app: staleCopy, lastUsedDate: .distantPast, sizeBytes: 1_000)],
            installed: { [inUse] },
            trashed: trashed
        )

        #expect(trashed.value == [staleCopy.bundleURL])
    }

    @Test func removingEveryCopyTakesTheSupportFiles() async {
        let first = Self.app("Stale")
        let second = Self.app("Stale", at: "/Users/me/Applications")
        let trashed = TestBox<Set<URL>>([])
        _ = await uninstallRun(
            selecting: [
                UnusedApp(app: first, lastUsedDate: .distantPast, sizeBytes: 1_000),
                UnusedApp(app: second, lastUsedDate: .distantPast, sizeBytes: 1_000),
            ],
            installed: { [] },
            trashed: trashed
        )

        #expect(trashed.value == [first.bundleURL, second.bundleURL, Self.supportFile])
    }

    @Test func unreadableInstalledAppsKeepTheSupportFiles() async {
        struct Unreadable: Error {}
        let stale = Self.app("Stale")
        let trashed = TestBox<Set<URL>>([])
        _ = await uninstallRun(
            selecting: [UnusedApp(app: stale, lastUsedDate: .distantPast, sizeBytes: 1_000)],
            installed: { throw Unreadable() },
            trashed: trashed
        )

        #expect(trashed.value == [stale.bundleURL])
    }

    // MARK: - Trash versus permanent

    /// The mapping has to agree with where `SystemJunkDeleter` really sends each
    /// root, in the direction that matters: nothing unflagged may be deleted for good.
    ///
    /// Language files are stubbed out because locating them walks every installed
    /// app, too slow for the main actor these suites share; the category answers
    /// `true` whichever root its files came from.
    @Test func everyRootTheDeleterRemovesForGoodIsFlaggedPermanent() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let provider = DefaultSystemPathProvider(
            homeDirectory: home,
            languageFileLocator: LanguageFileLocator(scanRoots: [], activeLanguageCodes: [])
        )
        #expect(ScanCategory.languageFiles.removalIsPermanent)
        for root in provider.roots() {
            let inside = root.url.appendingPathComponent("item").path
            let isPermanent = SystemJunkDeleter.requiresHelper(path: inside)
                || SystemJunkDeleter.isInUserTrash(path: inside, homeDirectory: home)
            if isPermanent {
                #expect(root.category.removalIsPermanent, "\(root.url.path) is deleted for good")
            }
        }
    }

    private func junkViewModel(
        _ files: [ScannedFile],
        cleaner: @escaping SmartScanViewModel.JunkCleaner = { .removing($0) }
    ) async -> SmartScanViewModel {
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.plan([CareFinding(payload: .junk(ScanResult(items: files)))]) },
            junkCleaner: cleaner
        )
        await vm.scan()
        return vm
    }

    private nonisolated static let userCache = file("/Users/me/Library/Caches/a", size: 700, category: .userCache)
    private nonisolated static let systemCache = file("/Library/Caches/b", size: 300, category: .systemCache)

    @Test func junkBoundForTheTrashDoesNotAskFirst() async {
        let vm = await junkViewModel([Self.userCache])
        #expect(!vm.runIncludesPermanentDelete)
        await vm.requestRun()
        #expect(vm.phaseID == "done", "nothing irreversible, so it runs on one tap")
    }

    @Test func junkRemovedForGoodAsksFirstAndSaysSo() async {
        let vm = await junkViewModel([Self.systemCache])
        #expect(vm.runIncludesPermanentDelete)
        let line = vm.runActionSummary.first
        #expect(line?.isPermanent == true)
        #expect(line?.text.hasPrefix("Permanently removes") == true)
    }

    @Test func mixedJunkNamesBothDestinations() async {
        let vm = await junkViewModel([Self.userCache, Self.systemCache])
        let line = vm.runActionSummary.first
        #expect(line?.isPermanent == true)
        let trashBytes = CareFindingCopy.formattedBytes(700)
        let permanentBytes = CareFindingCopy.formattedBytes(300)
        #expect(line?.text == "Moves \(trashBytes) of junk to the Trash and permanently removes \(permanentBytes)")
    }

    // MARK: - The receipt tells the truth

    private func receipt(of vm: SmartScanViewModel) -> CareReceipt? {
        if case .done(let receipt) = vm.phase { return receipt }
        Issue.record("expected .done, got \(vm.phase)")
        return nil
    }

    @Test func aJunkLineKeepsFreedAndTrashedApart() async {
        let vm = await junkViewModel([Self.userCache, Self.systemCache]) { files in
            JunkRemovalReport(bytesFreed: 300, bytesMovedToTrash: 700, removedCount: files.count)
        }
        await vm.run()

        let done = receipt(of: vm)
        #expect(done?.totalBytesFreed == 300)
        #expect(done?.totalBytesMovedToTrash == 700)
        #expect(done?.hasTrashRecoverableItems == true, "the receipt has to offer the way back")
    }

    @Test func aJunkFailureIsReportedAsPartial() async {
        let vm = await junkViewModel([Self.userCache, Self.systemCache]) { _ in
            JunkRemovalReport(bytesMovedToTrash: 700, removedCount: 1, failedCount: 1)
        }
        await vm.run()

        let line = receipt(of: vm)?.lines.first
        #expect(line?.itemsProcessed == 1)
        #expect(line?.outcome == .partial(failedCount: 1))
    }

    @Test func aJunkCleanThatRemovedNothingIsAFailure() async {
        let cleaned = TestBox(false)
        let vm = await junkViewModel([Self.userCache]) { _ in JunkRemovalReport(failedCount: 1) }
        vm.onJunkCleaned = { cleaned.value = true }
        await vm.run()

        let line = receipt(of: vm)?.lines.first
        #expect(line?.itemsProcessed == 0)
        if case .failed = line?.outcome {} else { Issue.record("expected a failure, got \(String(describing: line?.outcome))") }
        #expect(!cleaned.value, "nothing changed, so nothing downstream should drop its results")
    }

    /// A stale list isn't a failure, and has to leave the feed through the re-check.
    @Test func junkThatHadAlreadyGoneCountsAsHandled() async {
        let vm = await junkViewModel([Self.userCache]) { _ in JunkRemovalReport() }
        await vm.run()
        #expect(receipt(of: vm)?.lines.first?.itemsProcessed == 1)
    }

    @Test func recycledFilesAreReportedAsInTheTrash() async {
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.overlappingPlan },
            recycleFiles: { Set($0) }
        )
        await vm.scan()
        vm.setDownloads([Self.sharedCopy.url], selected: true)
        await vm.run()

        let done = receipt(of: vm)
        #expect(done?.totalBytesFreed == 0, "in the Trash isn't freed yet")
        #expect(done?.totalBytesMovedToTrash == 5_000, "one file, credited once")
    }

    /// `CareHistoryStore` drops the whole log when any receipt fails to decode.
    @Test func aReceiptSavedBeforeTheTrashSplitStillDecodes() throws {
        let saved = #"{"kind":"junkCleanup","itemsProcessed":2,"bytesFreed":99,"outcome":{"success":{}}}"#
        let line = try JSONDecoder().decode(CareReceiptLine.self, from: Data(saved.utf8))
        #expect(line.bytesFreed == 99)
        #expect(line.bytesMovedToTrash == 0)
    }

    // MARK: - A plan can outlive what it found

    @Test func aChangedDuplicateGroupIsLeftAlone() async {
        let trashed = TestBox<Set<URL>>([])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in Self.overlappingPlan },
            recycleFiles: Self.trashRecycler(trashed),
            duplicateGroupIsIntact: { _ in false }
        )
        await vm.scan()
        await vm.run()

        #expect(trashed.value.isEmpty)
        if case .failed = receipt(of: vm)?.lines.first?.outcome {} else {
            Issue.record("the receipt has to say the copies stayed")
        }
    }

    @Test func aDuplicateGroupIsCheckedAgainstTheDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func scanned(_ name: String) throws -> ScannedFile {
            let url = root.appendingPathComponent(name)
            try Data([1]).write(to: url)
            let date = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return ScannedFile(url: url, size: 1, lastAccessDate: nil, lastModifiedDate: date, category: .largeFile)
        }
        let original = try scanned("original")
        let copy = try scanned("copy")
        let group = DuplicateGroup(files: [original, copy])
        #expect(group.isUnchangedOnDisk())

        // A copy that has gone leaves the original standing.
        try FileManager.default.removeItem(at: copy.url)
        #expect(group.isUnchangedOnDisk())

        // Edited since the scan, so it may no longer match.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 3_600)],
            ofItemAtPath: original.url.path
        )
        #expect(!group.isUnchangedOnDisk())

        // No original, so its "redundant" copy could be the only one left.
        try FileManager.default.removeItem(at: original.url)
        #expect(!group.isUnchangedOnDisk())
    }

    // MARK: - Review follow-ups

    /// The scan honoured the Ignore List as it stood; an entry added while the
    /// results sat on screen still has to stop the Run.
    @Test func aRunLeavesWhatTheIgnoreListNowCovers() async {
        let ignoredApp = Self.app("Old", at: "/Users/me/Archive")
        let trashed = TestBox<Set<URL>>([])
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in
                Self.plan([
                    CareFinding(payload: .downloads([DownloadItem(file: Self.sharedCopy, sourceApp: nil)])),
                    CareFinding(payload: .unsupportedApps([UnsupportedApp(app: ignoredApp, reason: .incompatibleArchitecture)])),
                    CareFinding(payload: .unusedApps([UnusedApp(app: ignoredApp, lastUsedDate: .distantPast, sizeBytes: 1)])),
                ])
            },
            recycleFiles: Self.trashRecycler(trashed),
            currentExclusions: { [URL(fileURLWithPath: "/Downloads"), URL(fileURLWithPath: "/Users/me/Archive")] }
        )
        await vm.scan()
        vm.setDownloads([Self.sharedCopy.url], selected: true)
        vm.setUnsupportedApps([ignoredApp.id], selected: true)
        vm.setUnusedApps([ignoredApp.id], selected: true)
        await vm.run()

        #expect(trashed.value.isEmpty)
    }

    /// No scan-time date means nothing to compare against, so the group can't be
    /// shown to be unchanged.
    @Test func aGroupMemberWithNoScanDateFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try ["original", "copy"].map { name -> ScannedFile in
            let url = root.appendingPathComponent(name)
            try Data([1]).write(to: url)
            return ScannedFile(url: url, size: 1, lastAccessDate: nil, lastModifiedDate: nil, category: .largeFile)
        }
        #expect(!DuplicateGroup(files: files).isUnchangedOnDisk())
    }

    /// A project folder the deleter can only remove from for good can't feed a
    /// category the confirmation promises goes to the Trash.
    @Test(arguments: ["/Library/Caches/proj", "/private/var/folders/xy/proj", "/Applications/Tool.app/proj"])
    func aProjectFolderOnlyTheHelperCanEmptyIsRefused(path: String) throws {
        let suite = UserDefaults.testSuiteName("SmartScanDataSafety.webDev")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WebDevScanScopeStore(defaults: defaults)

        store.selectFolder(URL(fileURLWithPath: path))
        #expect(store.isDefault)

        // A pick saved before the rule existed is dropped too.
        defaults.set(path, forKey: "webDevJunk.scanFolderPath")
        #expect(WebDevScanScopeStore(defaults: defaults).scanRoots.isEmpty)
    }

    @Test func aHelperThatStoppedAnsweringIsNotCalledAFailure() async {
        let vm = await junkViewModel([Self.userCache, Self.systemCache]) { _ in
            JunkRemovalReport(bytesMovedToTrash: 700, removedCount: 1, unconfirmedCount: 1)
        }
        await vm.run()

        let line = receipt(of: vm)?.lines.first
        #expect(line?.outcome == .success)
        #expect(line?.unconfirmedCount == 1)
        #expect(line?.itemsProcessed == 1)
    }

    /// A changed group still has to say so when every other copy was taken by an
    /// earlier card and nothing is left for this one to move.
    @Test func aChangedGroupIsReportedEvenWhenNothingElseIsLeftToMove() async {
        let changedCopy = Self.file("/Downloads/changed-copy.bin")
        let changed = DuplicateGroup(files: [Self.file("/Downloads/changed.bin"), changedCopy])
        let bigDownload = Self.file("/Downloads/big.iso", size: 9_000_000, category: .largeFile)
        let vm = SmartScanViewModel(
            scanEngine: { _, _ in
                Self.plan([
                    CareFinding(payload: .duplicates([changed, DuplicateGroup(files: [Self.keptOriginal, Self.sharedCopy])])),
                    CareFinding(payload: .downloads([
                        DownloadItem(file: bigDownload, sourceApp: nil),
                        DownloadItem(file: Self.sharedCopy, sourceApp: nil),
                    ])),
                ])
            },
            recycleFiles: { Set($0) },
            duplicateGroupIsIntact: { $0 != changed }
        )
        await vm.scan()
        vm.setDownloads([bigDownload.url, Self.sharedCopy.url], selected: true)
        await vm.run()

        let line = receipt(of: vm)?.lines.first { $0.kind == .duplicates }
        if case .failed = line?.outcome {} else {
            Issue.record("the changed group has to reach the receipt, got \(String(describing: line?.outcome))")
        }
    }

    @Test func updatesThatAllFailTheCheckAreAFailure() async {
        let unsafe = Self.update(for: Self.app("Unsafe"), url: "http://example.com/a.dmg")
        let vm = SmartScanViewModel(scanEngine: { _, _ in Self.plan([CareFinding(payload: .appUpdates([unsafe]))]) })
        await vm.scan()
        await vm.run()

        if case .failed = receipt(of: vm)?.lines.first?.outcome {} else {
            Issue.record("nothing opened, so nothing happened")
        }
    }

    // MARK: - The Ignore List

    /// The standalone Applications section already filters this list; Smart Scan
    /// went on offering ignored apps for removal.
    @Test func unsupportedAppsHonorTheIgnoreList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Old.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        // A thin PowerPC Mach-O header: big-endian magic, CPU_TYPE_POWERPC.
        try Data([0xFE, 0xED, 0xFA, 0xCE, 0, 0, 0, 18]).write(to: macOS.appendingPathComponent("Old"))
        let old = AppInfo(name: "Old", bundleID: "com.example.old", version: "1", bundleURL: bundle, isAppStore: false)

        let suite = UserDefaults.testSuiteName("SmartScanDataSafety")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exclusions = ExclusionsStore(defaults: defaults)
        let stats = SystemStatsService(autostart: false)
        let runners = CareScanEngine.UnitRunners.live(exclusions: exclusions, statsService: stats)

        #expect(try await runners.unsupportedApps([old]).count == 1, "the fixture has to read as unsupported")

        exclusions.add(path: root.path)
        #expect(try await runners.unsupportedApps([old]).isEmpty)
        withExtendedLifetime((exclusions, stats)) {}
    }
}
