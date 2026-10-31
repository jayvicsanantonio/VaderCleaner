// ProtectionPrivacyModelFlowTests.swift
// Pins the Protection Manager's privacy model beyond basic selection: what search narrows, what a removal reports and keeps ticked, how a rescan treats the selection, and whole-browser removal for the dashboard tiles.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite
struct ProtectionPrivacyModelFlowTests {

    private static let cookies = [
        PrivacyItem(id: ".apple.com", label: ".apple.com", count: 2, hostKey: ".apple.com"),
        PrivacyItem(id: ".bing.com", label: ".bing.com", count: 1, hostKey: ".bing.com")
    ]

    private func makeModel(
        browsers: [Browser] = [.chrome],
        count: @escaping ProtectionPrivacyModel.CountProvider = { _, _ in 3 },
        items: @escaping ProtectionPrivacyModel.ItemsProvider = { _, category in
            category == .cookies ? ProtectionPrivacyModelFlowTests.cookies : []
        },
        availability: @escaping ProtectionPrivacyModel.AvailabilityProvider = { _, _ in .available },
        remove: @escaping ProtectionPrivacyModel.Remove = { _ in }
    ) -> ProtectionPrivacyModel {
        ProtectionPrivacyModel(
            detect: { browsers },
            count: count,
            items: items,
            availability: availability,
            remove: remove
        )
    }

    // MARK: - Search

    @Test
    func searchNarrowsItemsAndCategories() async {
        let model = makeModel()
        await model.scan()

        #expect(model.visibleItems(.chrome, .cookies, search: "apple").map(\.id) == [".apple.com"])
        #expect(model.isCategoryVisible(.chrome, .cookies, search: "apple"))
        #expect(!model.isCategoryVisible(.chrome, .cachedFiles, search: "apple"))
        #expect(model.isCategoryVisible(.chrome, .cachedFiles, search: "cached"))
        #expect(model.visibleItems(.chrome, .cookies, search: "cookies").count == 2, "naming the category shows all of it")
        #expect(model.isCategoryVisible(.chrome, .cachedFiles, search: ""))
    }

    @Test
    func aBrowserMatchesWhenAnyOfItsCategoriesDo() async {
        let model = makeModel()
        await model.scan()

        #expect(model.browserMatches(.chrome, search: "bing"))
        #expect(!model.browserMatches(.chrome, search: "nothing-like-this"))
        #expect(model.browserMatches(.chrome, search: ""))
    }

    @Test
    func selectAllTakesOnlyWhatSearchLeavesVisible() async {
        let model = makeModel()
        await model.scan()

        model.setAllSelected(true, browser: .chrome, search: "apple")

        #expect(model.isItemSelected(.chrome, .cookies, ".apple.com"))
        #expect(!model.isItemSelected(.chrome, .cookies, ".bing.com"))
        #expect(model.categoryState(.chrome, .cachedFiles) == .off)
        #expect(model.selectedCount == 1)
    }

    @Test
    func deselectAllLeavesWhatSearchHides() async {
        let model = makeModel()
        await model.scan()
        model.setAllSelected(true, browser: .chrome)

        model.setAllSelected(false, browser: .chrome, search: "apple")

        #expect(!model.isItemSelected(.chrome, .cookies, ".apple.com"))
        #expect(model.isItemSelected(.chrome, .cookies, ".bing.com"))
    }

    // MARK: - Selection

    @Test
    func selectAllSkipsEmptyCategories() async {
        let model = makeModel(count: { _, category in category == .cachedFiles ? 0 : 3 })
        await model.scan()

        model.setAllSelected(true, browser: .chrome)

        #expect(model.categoryState(.chrome, .cachedFiles) == .off)
        #expect(model.categoryState(.chrome, .tabsFromLastSession) == .on)
    }

    @Test
    func theSelectionIsReportedPerBrowser() async {
        let model = makeModel(browsers: [.chrome, .brave])
        await model.scan()

        model.toggleCategory(.chrome, .cachedFiles)

        #expect(model.hasSelection(in: .chrome))
        #expect(!model.hasSelection(in: .brave))
        #expect(model.hasSelection)
    }

    @Test
    func theRemovalSummaryNamesEachBrowserAndCategory() async {
        let model = makeModel(browsers: [.chrome, .brave])
        await model.scan()
        model.toggleItem(.chrome, .cookies, ".apple.com")
        model.toggleCategory(.chrome, .cachedFiles)
        model.toggleCategory(.brave, .tabsFromLastSession)

        #expect(model.removalSummaryLines == [
            "Google Chrome: Cookies (1 of 2), Cached Files",
            "Brave: Tabs From Last Session"
        ])
    }

    @Test
    func aRescanDropsSelectionsForItemsThatAreGone() async {
        let current = TestBox(Self.cookies)
        let total = TestBox(3)
        let model = makeModel(
            count: { _, _ in total.value },
            items: { _, category in category == .cookies ? current.value : [] }
        )
        await model.scan()
        model.setAllSelected(true, browser: .chrome)

        current.value = [Self.cookies[1]]
        total.value = 0
        await model.scan()

        #expect(!model.isItemSelected(.chrome, .cookies, ".apple.com"))
        #expect(model.isItemSelected(.chrome, .cookies, ".bing.com"))
        #expect(model.categoryState(.chrome, .cachedFiles) == .off, "nothing left to remove there")
    }

    // MARK: - Counts and availability

    @Test
    func theBrowserTotalCountsOnlyWhatCanBeRemoved() async {
        let model = makeModel(count: { _, category in category.kind == .removable ? 10 : 1_000 })
        await model.scan()

        #expect(model.removableCount(.chrome) == 40)
    }

    @Test
    func availabilityIsPublishedPerCategory() async {
        let model = makeModel(availability: { _, category in
            category == .cookies ? .unsupported : category == .cachedFiles ? .unreadable : .available
        })
        await model.scan()

        #expect(model.availability(.chrome, .cookies) == .unsupported)
        #expect(model.availability(.chrome, .cachedFiles) == .unreadable)
        #expect(model.availability(.chrome, .downloadsHistory) == .available)
    }

    // MARK: - Removal

    @Test
    func aFailedRemovalIsReportedRescansAndKeepsWhatIsLeftTicked() async {
        let scans = TestBox(0)
        let model = makeModel(
            count: { _, _ in
                scans.withLock { $0 += 1 }
                return 3
            },
            remove: { _ in throw PrivacyRemovalError.incomplete }
        )
        await model.scan()
        let scansBefore = scans.value
        model.toggleCategory(.chrome, .cachedFiles)

        await model.remove()

        #expect(model.removalFailureMessage != nil)
        #expect(scans.value > scansBefore, "the list has to show what actually went")
        #expect(model.categoryState(.chrome, .cachedFiles) == .on, "still there, so still ticked for a retry")
        #expect(model.phase == .ready)
    }

    @Test
    func aLaterSuccessClearsAnEarlierFailure() async {
        let fails = TestBox(true)
        let model = makeModel(remove: { _ in
            if fails.value { throw PrivacyRemovalError.incomplete }
        })
        await model.scan()
        model.toggleCategory(.chrome, .cachedFiles)
        await model.remove()

        fails.value = false
        await model.remove()

        #expect(model.removalFailureMessage == nil)
        #expect(!model.hasSelection)
    }

    @Test
    func aRemovalTellsAnyoneWatching() async {
        let changes = TestBox(0)
        let model = makeModel()
        model.onDataChanged = { changes.withLock { $0 += 1 } }
        await model.scan()
        model.toggleCategory(.chrome, .cachedFiles)

        await model.remove()

        #expect(changes.value == 1)
    }

    @Test
    func aBackgroundRefreshCannotInterruptARemoval() async {
        let gate = SuspendingCallGate()
        let model = makeModel(remove: { _ in await gate.hold() })
        await model.scan()
        model.toggleCategory(.chrome, .cachedFiles)

        let removal = Task { await model.remove() }
        #expect(await pollUntil { model.phase == .removing })
        await model.scan()
        #expect(model.phase == .removing)
        gate.open()
        await removal.value

        #expect(model.phase == .ready)
        #expect(!model.hasSelection, "the removal finished its own cleanup")
    }

    @Test
    func removingABrowsersDataTakesEveryRemovableCategoryWithAnythingInIt() async {
        let requests = TestBox<[PrivacyRemovalRequest]>([])
        let model = makeModel(
            browsers: [.chrome, .brave],
            count: { _, category in category == .tabsFromLastSession ? 0 : 3 },
            remove: { received in requests.value = received }
        )
        await model.scan()
        model.toggleCategory(.brave, .cachedFiles)

        let removed = await model.removeAllData(for: .chrome)

        #expect(removed)
        #expect(Set(requests.value.map(\.category)) == [.cookies, .downloadsHistory, .cachedFiles])
        #expect(requests.value.allSatisfy { $0.browser == .chrome && $0.scope == .wholeCategory })
        #expect(model.hasSelection(in: .brave), "another browser's selection is untouched")
    }

    @Test
    func removingABrowsersDataWhileItRunsIsBlocked() async {
        let model = makeModel(remove: { _ in throw PrivacyRemovalError.browserRunning(.chrome) })
        await model.scan()

        let removed = await model.removeAllData(for: .chrome)

        #expect(!removed)
        #expect(model.blockedByRunningBrowser == .chrome)
    }
}
