// ProtectionPrivacyModelTests.swift
// Drives the ProtectionPrivacyModel — scan caching, category vs per-item selection and tri-state, removal-request building, and the running-browser block — through injected fakes.

import XCTest
@testable import VaderCleaner

@MainActor
final class ProtectionPrivacyModelTests: XCTestCase {

    private func makeModel(
        browsers: [Browser] = [.chrome],
        count: @escaping ProtectionPrivacyModel.CountProvider = { _, _ in 0 },
        items: @escaping ProtectionPrivacyModel.ItemsProvider = { _, _ in [] },
        remove: @escaping ProtectionPrivacyModel.Remove = { _ in }
    ) -> ProtectionPrivacyModel {
        ProtectionPrivacyModel(detect: { browsers }, count: count, items: items, remove: remove)
    }

    private let cookieItems = [
        PrivacyItem(id: ".a.com", label: ".a.com", count: 2, hostKey: ".a.com"),
        PrivacyItem(id: ".b.com", label: ".b.com", count: 1, hostKey: ".b.com")
    ]

    func test_scan_cachesCountsAndItems() async {
        let model = makeModel(
            count: { _, c in c == .cookies ? 3 : 0 },
            items: { _, c in c == .cookies ? self.cookieItems : [] }
        )

        await model.scan()

        XCTAssertEqual(model.browsers, [.chrome])
        XCTAssertEqual(model.count(.chrome, .cookies), 3)
        XCTAssertEqual(model.items(.chrome, .cookies), cookieItems)
        XCTAssertEqual(model.phase, .ready)
    }

    func test_toggleCategory_expandable_selectsAllItemsThenItemTogglesToMixed() async {
        let model = makeModel(count: { _, _ in 3 }, items: { _, c in c == .cookies ? self.cookieItems : [] })
        await model.scan()

        XCTAssertEqual(model.categoryState(.chrome, .cookies), .off)
        model.toggleCategory(.chrome, .cookies)
        XCTAssertEqual(model.categoryState(.chrome, .cookies), .on)
        XCTAssertTrue(model.isItemSelected(.chrome, .cookies, ".a.com"))

        model.toggleItem(.chrome, .cookies, ".a.com")
        XCTAssertEqual(model.categoryState(.chrome, .cookies), .mixed)
    }

    func test_removalRequests_partialUsesItems_fullCollapsesToWholeCategory() async {
        let model = makeModel(count: { _, _ in 3 }, items: { _, c in c == .cookies ? self.cookieItems : [] })
        await model.scan()

        model.toggleItem(.chrome, .cookies, ".a.com")
        var requests = model.removalRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].scope, .items(hostKeys: [".a.com"], rowIDs: []))

        model.toggleItem(.chrome, .cookies, ".b.com")
        requests = model.removalRequests()
        XCTAssertEqual(requests[0].scope, .wholeCategory)
    }

    func test_toggleCategory_informationalIsIgnored() async {
        let model = makeModel(count: { _, _ in 5 })
        await model.scan()

        model.toggleCategory(.chrome, .savedPasswords)

        XCTAssertEqual(model.categoryState(.chrome, .savedPasswords), .off)
        XCTAssertFalse(model.hasSelection)
    }

    func test_remove_whenBrowserRunning_recordsBlockAndKeepsSelection() async {
        let model = makeModel(
            count: { _, _ in 1 },
            remove: { _ in throw PrivacyRemovalError.browserRunning(.chrome) }
        )
        await model.scan()
        model.toggleCategory(.chrome, .cachedFiles)

        await model.remove()

        XCTAssertEqual(model.blockedByRunningBrowser, .chrome)
        XCTAssertTrue(model.hasSelection, "A blocked removal must not drop the selection")
    }

    func test_setAllSelected_selectsEveryRemovableCategory() async {
        let model = makeModel(count: { _, _ in 2 }, items: { _, c in c == .cookies ? self.cookieItems : [] })
        await model.scan()

        model.setAllSelected(true, browser: .chrome)

        XCTAssertEqual(model.categoryState(.chrome, .cookies), .on)
        XCTAssertEqual(model.categoryState(.chrome, .cachedFiles), .on)
        XCTAssertEqual(model.categoryState(.chrome, .savedPasswords), .off, "Informational stays unselected")

        model.setAllSelected(false, browser: .chrome)
        XCTAssertFalse(model.hasSelection)
    }
}
