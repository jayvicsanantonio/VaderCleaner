// ApplicationsManagerModelTests.swift
// Tests the pure facet/filter/sort helpers behind the Applications Manager's Uninstaller pane — store and vendor counts, facet filtering, and the Name/Last Opened/Size orderings — over in-memory fixtures so no real apps are touched.

import XCTest
@testable import VaderCleaner

final class ApplicationsManagerModelTests: XCTestCase {

    // MARK: - Fixtures

    private func app(_ name: String, _ bundleID: String, appStore: Bool = false, lastUsed: Date? = nil) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: appStore,
            lastUsedDate: lastUsed
        )
    }

    private lazy var apps: [AppInfo] = [
        app("Safari", "com.apple.Safari", appStore: false),
        app("Pages", "com.apple.iWork.Pages", appStore: true),
        app("Chrome", "com.google.Chrome", appStore: false),
        app("VS Code", "com.microsoft.VSCode", appStore: false),
        app("Firefox", "org.mozilla.firefox", appStore: true),
    ]

    // MARK: - Store counts

    /// App Store membership comes straight off `AppInfo.isAppStore`.
    func test_storeCounts_splitsByReceipt() {
        let counts = ApplicationsManagerModel.storeCounts(apps: apps)
        XCTAssertEqual(counts.appStore, 2)
        XCTAssertEqual(counts.other, 3)
    }

    // MARK: - Vendor counts

    /// Only vendors that actually appear are returned, each with its count, in
    /// descending-count order (ties broken by vendor title).
    func test_vendorCounts_listsPopulatedVendors() {
        let counts = ApplicationsManagerModel.vendorCounts(apps: apps)
        XCTAssertEqual(counts.first?.vendor, .apple)   // Apple has 2, the most
        XCTAssertEqual(counts.first?.count, 2)
        let vendors = Set(counts.map(\.vendor))
        XCTAssertEqual(vendors, [.apple, .google, .microsoft, .mozilla])
    }

    // MARK: - Facet filtering

    /// `.all` returns every app.
    func test_filter_all_returnsEverything() {
        let result = ApplicationsManagerModel.filter(
            apps, facet: .all, search: "", unusedIDs: [], selectedIDs: []
        )
        XCTAssertEqual(result.count, apps.count)
    }

    /// `.unused` keeps only apps whose id is in the unused set.
    func test_filter_unused_keepsOnlyUnused() {
        let unused: Set<AppInfo.ID> = [apps[0].id, apps[2].id]
        let result = ApplicationsManagerModel.filter(
            apps, facet: .unused, search: "", unusedIDs: unused, selectedIDs: []
        )
        XCTAssertEqual(Set(result.map(\.id)), unused)
    }

    /// `.selected` keeps only apps whose id is in the selection set.
    func test_filter_selected_keepsOnlySelected() {
        let selected: Set<AppInfo.ID> = [apps[1].id]
        let result = ApplicationsManagerModel.filter(
            apps, facet: .selected, search: "", unusedIDs: [], selectedIDs: selected
        )
        XCTAssertEqual(result.map(\.id), [apps[1].id])
    }

    /// A store facet keeps only apps with the matching receipt state.
    func test_filter_store_keepsMatchingStore() {
        let result = ApplicationsManagerModel.filter(
            apps, facet: .store(isAppStore: true), search: "", unusedIDs: [], selectedIDs: []
        )
        XCTAssertEqual(Set(result.map(\.name)), ["Pages", "Firefox"])
    }

    /// A vendor facet keeps only apps from that vendor.
    func test_filter_vendor_keepsMatchingVendor() {
        let result = ApplicationsManagerModel.filter(
            apps, facet: .vendor(.apple), search: "", unusedIDs: [], selectedIDs: []
        )
        XCTAssertEqual(Set(result.map(\.name)), ["Safari", "Pages"])
    }

    /// Search narrows within the active facet, case-insensitively on the name.
    func test_filter_searchNarrowsWithinFacet() {
        let result = ApplicationsManagerModel.filter(
            apps, facet: .all, search: "fire", unusedIDs: [], selectedIDs: []
        )
        XCTAssertEqual(result.map(\.name), ["Firefox"])
    }

    // MARK: - Sorting

    /// Name sort is case-insensitive ascending.
    func test_sort_name_isAlphabetical() {
        let result = ApplicationsManagerModel.sort(
            apps, by: .name, sizes: [:]
        )
        XCTAssertEqual(result.map(\.name), ["Chrome", "Firefox", "Pages", "Safari", "VS Code"])
    }

    /// Size sort is largest-first; apps without a measured size sink to the end.
    func test_sort_size_isLargestFirst() {
        let sizes: [AppInfo.ID: Int64] = [
            apps[0].id: 100,
            apps[1].id: 300,
            apps[2].id: 200,
        ]
        let result = ApplicationsManagerModel.sort(
            apps, by: .size, sizes: sizes
        )
        XCTAssertEqual(Array(result.prefix(3)).map(\.name), ["Pages", "Chrome", "Safari"])
    }

    /// Last-opened sort is most-recent-first; apps without a date sink to the
    /// end. The date rides on `AppInfo`, resolved during discovery.
    func test_sort_lastOpened_isMostRecentFirst() {
        let now = Date()
        let dated = [
            app("Safari", "com.apple.Safari", lastUsed: now.addingTimeInterval(-100)),
            app("Pages", "com.apple.iWork.Pages", lastUsed: now),
            app("Chrome", "com.google.Chrome", lastUsed: now.addingTimeInterval(-50)),
            app("Firefox", "org.mozilla.firefox", lastUsed: nil),
        ]
        let result = ApplicationsManagerModel.sort(
            dated, by: .lastOpened, sizes: [:]
        )
        XCTAssertEqual(result.map(\.name), ["Pages", "Chrome", "Safari", "Firefox"])
    }

    // MARK: - listState

    /// An empty list while work is still running is not an empty result.
    /// The empty states in this manager assert facts — "Everything is in
    /// order", "No extensions were found" — and saying them mid-scan is
    /// simply untrue.
    func test_listState_emptyWhileLoadingIsLoading() {
        XCTAssertEqual(ApplicationsManagerModel.listState(isLoading: true, isEmpty: true), .loading)
    }

    /// An empty list once the work is done is a real result.
    func test_listState_emptyAfterLoadingIsEmpty() {
        XCTAssertEqual(ApplicationsManagerModel.listState(isLoading: false, isEmpty: true), .empty)
    }

    /// A pane that already has results keeps showing them through a
    /// refresh. Blanking a populated list to a spinner loses the user's
    /// place for no gain.
    func test_listState_populatedListStaysContentWhileReloading() {
        XCTAssertEqual(ApplicationsManagerModel.listState(isLoading: true, isEmpty: false), .content)
    }

    func test_listState_populatedAndIdleIsContent() {
        XCTAssertEqual(ApplicationsManagerModel.listState(isLoading: false, isEmpty: false), .content)
    }
}

/// Sort scoping and the shared search rule — the two behaviours that were
/// previously restated (or silently skipped) per pane.
final class ApplicationsManagerControlScopeTests: XCTestCase {

    // MARK: - sortOptions

    /// Every pane can order by name, so the fallback is always available.
    func test_sortOptions_everyPaneSupportsName() {
        for pane in [ApplicationsManagerView.Pane.uninstaller, .updater,
                     .extensions, .leftovers, .unsupported] {
            XCTAssertTrue(
                ApplicationsManagerModel.sortOptions(for: pane).contains(.name),
                "\(pane) must support name ordering"
            )
        }
    }

    /// Updates carry no size and no last-opened date, so the pane offers
    /// one option and the header shows no menu.
    func test_sortOptions_updaterOffersNameOnly() {
        XCTAssertEqual(ApplicationsManagerModel.sortOptions(for: .updater), [.name])
    }

    /// Extensions have a size but were never opened as apps.
    func test_sortOptions_extensionsOfferSizeButNotLastOpened() {
        let options = ApplicationsManagerModel.sortOptions(for: .extensions)
        XCTAssertTrue(options.contains(.size))
        XCTAssertFalse(options.contains(.lastOpened))
    }

    /// Unsupported apps carry a last-opened date but no measured size.
    func test_sortOptions_unsupportedOffersLastOpenedButNotSize() {
        let options = ApplicationsManagerModel.sortOptions(for: .unsupported)
        XCTAssertTrue(options.contains(.lastOpened))
        XCTAssertFalse(options.contains(.size))
    }

    // MARK: - resolvedSort

    /// A supported selection is honoured as-is.
    func test_resolvedSort_keepsASupportedSelection() {
        XCTAssertEqual(
            ApplicationsManagerModel.resolvedSort(.size, for: .uninstaller),
            .size
        )
    }

    /// Carrying "Size" into a pane with no sizes falls back to name,
    /// rather than leaving the header claiming an ordering that isn't in
    /// effect.
    func test_resolvedSort_fallsBackWhenTheSelectionIsUnsupported() {
        XCTAssertEqual(ApplicationsManagerModel.resolvedSort(.size, for: .updater), .name)
        XCTAssertEqual(ApplicationsManagerModel.resolvedSort(.lastOpened, for: .extensions), .name)
        XCTAssertEqual(ApplicationsManagerModel.resolvedSort(.size, for: .unsupported), .name)
    }

    // MARK: - matchesSearch

    /// An empty query matches everything, so an untouched field filters
    /// nothing out.
    func test_matchesSearch_emptyQueryMatchesEverything() {
        XCTAssertTrue(ApplicationsManagerModel.matchesSearch("", name: "Helio"))
        XCTAssertTrue(ApplicationsManagerModel.matchesSearch("   ", name: "Helio"))
    }

    func test_matchesSearch_matchesNameCaseInsensitively() {
        XCTAssertTrue(ApplicationsManagerModel.matchesSearch("hel", name: "Helio"))
        XCTAssertFalse(ApplicationsManagerModel.matchesSearch("zzz", name: "Helio"))
    }

    /// The inconsistency this replaces: a bundle ID found apps in some
    /// panes and nothing in others.
    func test_matchesSearch_matchesTheIdentifierToo() {
        XCTAssertTrue(
            ApplicationsManagerModel.matchesSearch("com.acme", name: "Helio", identifier: "com.acme.helio")
        )
    }

    /// Without an identifier only the name is considered — nothing is
    /// invented to match against.
    func test_matchesSearch_withoutAnIdentifierOnlyTheNameCounts() {
        XCTAssertFalse(ApplicationsManagerModel.matchesSearch("com.acme", name: "Helio"))
    }
}

/// The store tally behind the Updater's facet column. The count this
/// replaces was `total - appStore`, which quietly absorbed Homebrew rows
/// into Web the day a third channel was added.
final class UpdateStoreCountsTests: XCTestCase {

    /// Every source gets an entry, so the facet column can be built by
    /// iterating `UpdateSource.allCases` rather than listing rows by hand.
    func test_updateStoreCounts_coversEverySource() {
        let counts = ApplicationsManagerModel.updateStoreCounts([])
        XCTAssertEqual(Set(counts.keys), Set(UpdateSource.allCases))
        XCTAssertTrue(counts.values.allSatisfy { $0 == 0 })
    }

    /// The counts partition the list exactly — no update is missed and
    /// none is counted twice, whatever mix of channels is present.
    func test_updateStoreCounts_partitionTheList() {
        let updates = [
            update(bundleID: "a", source: .appStore),
            update(bundleID: "b", source: .sparkle),
            update(bundleID: "c", source: .homebrew),
            update(bundleID: "d", source: .homebrew),
        ]
        let counts = ApplicationsManagerModel.updateStoreCounts(updates)
        XCTAssertEqual(counts[.appStore], 1)
        XCTAssertEqual(counts[.sparkle], 1)
        XCTAssertEqual(counts[.homebrew], 2)
        XCTAssertEqual(counts.values.reduce(0, +), updates.count)
    }

    /// The regression that prompted this: with Homebrew rows present, Web
    /// must report only the Sparkle ones. The old subtraction reported
    /// every non-App-Store row, so a list of one web update and six casks
    /// showed "Web 7".
    func test_updateStoreCounts_webExcludesHomebrewRows() {
        let updates = [update(bundleID: "telegram", source: .sparkle)]
            + (0..<6).map { update(bundleID: "cask\($0)", source: .homebrew) }

        let counts = ApplicationsManagerModel.updateStoreCounts(updates)

        XCTAssertEqual(counts[.sparkle], 1)
        XCTAssertEqual(counts[.homebrew], 6)
    }

    private func update(bundleID: String, source: UpdateSource) -> UpdateInfo {
        UpdateInfo(
            appName: bundleID,
            bundleID: bundleID,
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleID).app"),
            installedVersion: "1.0",
            latestVersion: "2.0",
            source: source,
            updateURL: source == .homebrew ? nil : URL(string: "https://example.com/\(bundleID).zip")
        )
    }
}
