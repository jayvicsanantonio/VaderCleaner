// ProtectionDashboardCoordinationTests.swift
// Pins how the dashboard keeps its tiles, the manager, and Smart Scan in step: which browser data a tile removes, what it measures, when the manager refreshes, and which failures reach the user.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite
struct ProtectionDashboardCoordinationTests {

    private let threat = MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/evil.bin"), threatName: "A")

    private func makeSUT(
        browsers: [Browser] = [.chrome],
        sizes: @escaping PrivacyViewModel.Sizer = { _, _ in 100 },
        paths: @escaping PrivacyViewModel.PathsResolver = { browser, category in
            [URL(fileURLWithPath: "/tmp/\(browser.rawValue)/\(category.rawValue)")]
        },
        managerCount: @escaping ProtectionPrivacyModel.CountProvider = { _, _ in 3 },
        managerRemove: @escaping ProtectionPrivacyModel.Remove = { _ in },
        malwareScan: @escaping MalwareViewModel.Scan = { _, _ in [] },
        removeThreats: @escaping MalwareViewModel.RemoveThreats = { _ in [] }
    ) -> ProtectionDashboardViewModel {
        let malware = MalwareViewModel(
            checkInstalled: { true },
            databaseLastUpdated: { Date() },
            updateDatabase: { _ in },
            scan: malwareScan,
            removeThreats: removeThreats,
            notify: { _ in },
            shouldNotify: { false }
        )
        let privacy = PrivacyViewModel(
            detector: { browsers },
            sizer: sizes,
            pathsFor: paths,
            clearer: { _, _ in },
            clearRecentFiles: {}
        )
        let model = ProtectionPrivacyModel(
            detect: { browsers },
            count: managerCount,
            items: { _, _ in [] },
            remove: managerRemove
        )
        return ProtectionDashboardViewModel(malware: malware, privacy: privacy, protectionPrivacy: model)
    }

    // MARK: - Tile removal

    @Test
    func aTileRemovesOnlyWhatTheManagerWould() async {
        let requests = TestBox<[PrivacyRemovalRequest]>([])
        let sut = makeSUT(managerRemove: { requests.value = $0 })
        await sut.protectionPrivacy.scan()

        let cleared = await sut.clearPrivacyData(for: .chrome)

        #expect(cleared)
        let categories = Set(requests.value.map(\.category))
        #expect(categories == [.cookies, .downloadsHistory, .cachedFiles, .tabsFromLastSession])
        #expect(!categories.contains(.autofillValues))
        #expect(!categories.contains(.savedPasswords))
        #expect(!categories.contains(.browsingHistory))
    }

    @Test
    func aTileIsRefusedWhileItsBrowserRuns() async {
        let sut = makeSUT(managerRemove: { _ in throw PrivacyRemovalError.browserRunning(.chrome) })
        await sut.protectionPrivacy.scan()

        let cleared = await sut.clearPrivacyData(for: .chrome)

        #expect(!cleared)
        #expect(sut.protectionPrivacy.blockedByRunningBrowser == .chrome)
    }

    @Test
    func aManagerRemovalRefreshesTheTileSizes() async {
        let current = TestBox<Int64>(100)
        let sut = makeSUT(sizes: { _, _ in current.value })
        sut.privacy.beginScan()
        #expect(await pollUntil { sut.privacy.phase == .preview })
        await sut.protectionPrivacy.scan()
        #expect(sut.privacy.removableSize(for: .chrome) == 200)

        current.value = 10
        sut.protectionPrivacy.toggleCategory(.chrome, .cachedFiles)
        await sut.protectionPrivacy.remove()

        #expect(await pollUntil { sut.privacy.removableSize(for: .chrome) == 20 })
        #expect(sut.privacy.phase == .preview, "a refresh mustn't send the dashboard back to its loader")
    }

    @Test
    func aTileShowsOnlyWhileThereIsSomethingToRemove() async {
        let remaining = TestBox(3)
        let sut = makeSUT(managerCount: { _, _ in remaining.value })
        sut.privacy.beginScan()
        #expect(await pollUntil { sut.privacy.phase == .preview })

        #expect(sut.hasRemovablePrivacyData(for: .chrome), "falls back to sizes until the manager has scanned")
        await sut.protectionPrivacy.scan()
        #expect(sut.hasRemovablePrivacyData(for: .chrome))

        remaining.value = 0
        await sut.protectionPrivacy.scan()
        #expect(!sut.hasRemovablePrivacyData(for: .chrome), "a database file keeps its size after its rows are gone")
    }

    // MARK: - Manager refresh

    @Test
    func theManagerCanRefreshAfterItsFirstScan() async {
        let current = TestBox(3)
        let sut = makeSUT(managerCount: { _, _ in current.value })
        await sut.protectionPrivacy.scan()

        current.value = 7
        sut.refreshManagerPrivacy()

        #expect(await pollUntil { sut.protectionPrivacy.count(.chrome, .cookies) == 7 })
    }

    // MARK: - Failures

    @Test
    func everyKindOfRemovalFailureReachesTheSameAlert() async {
        let sut = makeSUT(
            managerRemove: { _ in throw PrivacyRemovalError.incomplete },
            removeThreats: { $0 }
        )
        await sut.protectionPrivacy.scan()
        sut.protectionPrivacy.toggleCategory(.chrome, .cachedFiles)
        await sut.protectionPrivacy.remove()
        #expect(sut.removalFailureMessage != nil)

        sut.dismissRemovalFailure()
        #expect(sut.removalFailureMessage == nil)

        sut.malware.seed(threats: [threat], clamAVAvailable: true, scannedAt: Date())
        await sut.malware.removeThreats([threat])
        #expect(sut.removalFailureMessage == "1 threat couldn't be removed and is still listed, so you can try again.")

        sut.dismissRemovalFailure()
        #expect(sut.removalFailureMessage == nil)
    }

    // MARK: - Smart Scan

    @Test
    func aLaterSmartScanUpdatesProtection() {
        let sut = makeSUT()

        sut.prewarmFromSmartScan(threats: [], clamAVAvailable: true, scannedAt: Date())
        #expect(sut.malware.phase == .clean)

        sut.prewarmFromSmartScan(threats: [threat], clamAVAvailable: true, scannedAt: Date())
        #expect(sut.malware.phase == .results([threat]))
    }

    @Test
    func threatsSmartScanRemovedLeaveProtection() {
        let sut = makeSUT()
        sut.prewarmFromSmartScan(threats: [threat], clamAVAvailable: true, scannedAt: Date())

        sut.smartScanRemoved(threats: [threat])

        #expect(sut.malware.phase == .done(removedCount: 1))
    }
}

@Suite
struct MalwareThreatConfirmationTests {

    private func threats(_ count: Int) -> [MalwareThreat] {
        (1...count).map { MalwareThreat(filePath: URL(fileURLWithPath: "/Users/me/file\($0).bin"), threatName: "A") }
    }

    @Test
    func theConfirmationNamesTheFilesItWillRemove() {
        let message = threats(2).namedRemovalConfirmationMessage
        #expect(message.contains("file1.bin"))
        #expect(message.contains("file2.bin"))
        #expect(message.contains("moved to the Trash"))
    }

    @Test
    func aLongListIsCutShort() {
        let message = threats(8).namedRemovalConfirmationMessage
        #expect(message.contains("file5.bin"))
        #expect(!message.contains("file6.bin"))
        #expect(message.contains("3 more"))
    }
}

@MainActor
@Suite
struct PrivacyViewModelRecentsTests {

    @Test
    func recentItemsAreOnlyReportedWhenPresent() async {
        let present = TestBox(false)
        let vm = PrivacyViewModel(
            detector: { [] },
            sizer: { _, _ in 0 },
            pathsFor: { _, _ in [] },
            clearer: { _, _ in },
            clearRecentFiles: { present.value = false },
            recentItemsPresent: { present.value }
        )

        await vm.preview()
        #expect(!vm.hasRecentItems)

        present.value = true
        await vm.preview()
        #expect(vm.hasRecentItems)

        try? await vm.clearRecentItems()
        #expect(!vm.hasRecentItems)
    }

    @Test
    func safariCookiesDoNotCountTowardsWhatItsTileCanRemove() async {
        let vm = PrivacyViewModel(
            detector: { [.safari, .chrome] },
            sizer: { _, _ in 100 },
            pathsFor: { browser, category in [URL(fileURLWithPath: "/tmp/\(browser.rawValue)/\(category.rawValue)")] },
            clearer: { _, _ in },
            clearRecentFiles: {}
        )
        await vm.preview()

        #expect(vm.removableSize(for: .safari) == 100, "cached files only: its cookies can't be removed yet")
        #expect(vm.removableSize(for: .chrome) == 200)
    }
}
