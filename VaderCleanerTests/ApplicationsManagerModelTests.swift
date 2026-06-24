// ApplicationsManagerModelTests.swift
// Tests the pure facet/filter/sort helpers behind the Applications Manager's Uninstaller pane — store and vendor counts, facet filtering, and the Name/Last Opened/Size orderings — over in-memory fixtures so no real apps are touched.

import XCTest
@testable import VaderCleaner

final class ApplicationsManagerModelTests: XCTestCase {

    // MARK: - Fixtures

    private func app(_ name: String, _ bundleID: String, appStore: Bool = false) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            version: "1.0",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isAppStore: appStore
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

    /// `.suspicious` is a parity placeholder with no members, so it filters to
    /// an empty list.
    func test_filter_suspicious_isEmpty() {
        let result = ApplicationsManagerModel.filter(
            apps, facet: .suspicious, search: "", unusedIDs: [], selectedIDs: []
        )
        XCTAssertTrue(result.isEmpty)
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
            apps, by: .name, sizes: [:], dates: [:]
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
            apps, by: .size, sizes: sizes, dates: [:]
        )
        XCTAssertEqual(Array(result.prefix(3)).map(\.name), ["Pages", "Chrome", "Safari"])
    }

    /// Last-opened sort is most-recent-first; apps without a date sink to the end.
    func test_sort_lastOpened_isMostRecentFirst() {
        let now = Date()
        let dates: [AppInfo.ID: Date] = [
            apps[0].id: now.addingTimeInterval(-100),
            apps[1].id: now,
            apps[2].id: now.addingTimeInterval(-50),
        ]
        let result = ApplicationsManagerModel.sort(
            apps, by: .lastOpened, sizes: [:], dates: dates
        )
        XCTAssertEqual(Array(result.prefix(3)).map(\.name), ["Pages", "Chrome", "Safari"])
    }
}
