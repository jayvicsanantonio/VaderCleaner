// ManagerRowVisibilityTests.swift
// Pins which rows a manager shows for a search, sort, and expansion, when its list returns to the top, and how the Cleanup dashboard accounts for groups that get no card.

import Foundation
import Testing
@testable import VaderCleaner
import VaderCleanerCore

@Suite("Manager row visibility")
@MainActor
struct ManagerRowVisibilityTests {

    private func row(_ title: String, size: Int64, children: [ManagerItem] = []) -> ManagerItem {
        ManagerItem(
            id: "/r/\(title)",
            title: title,
            subtitle: nil,
            size: size,
            sizeText: nil,
            systemImage: "doc",
            tint: .blue,
            children: children
        )
    }

    private var rows: [ManagerItem] {
        [
            row("Google", size: 300, children: [row("Chrome", size: 200), row("Drive", size: 100)]),
            row("Homebrew", size: 50),
        ]
    }

    private func titles(search: String = "", sort: ManagerSort = .size, expanded: Set<String> = []) -> [String] {
        SmartScanReviewManager
            .visibleRows(of: rows, search: search, sort: sort, expandedIDs: expanded)
            .map(\.title)
    }

    @Test("With no search, only expanded rows show their children")
    func expansion() {
        #expect(titles() == ["Google", "Homebrew"])
        #expect(titles(expanded: ["/r/Google"]) == ["Google", "Chrome", "Drive", "Homebrew"])
    }

    @Test("Search finds a child, showing its parent and only the children that matched")
    func searchFindsChildren() {
        #expect(titles(search: "chrome") == ["Google", "Chrome"])
    }

    @Test("A row matching by its own name keeps its children collapsed")
    func searchMatchingParent() {
        #expect(titles(search: "google") == ["Google"])
    }

    @Test("A row the user expanded shows all its children during a search")
    func searchRespectsExpansion() {
        #expect(titles(search: "chrome", expanded: ["/r/Google"]) == ["Google", "Chrome", "Drive"])
    }

    @Test("A search with no matches shows nothing")
    func searchWithoutMatches() {
        #expect(titles(search: "zzz").isEmpty)
    }

    @Test("Name sort reaches the children too")
    func nameSortOrdersChildren() {
        let sorted = SmartScanReviewManager.visibleRows(
            of: [row("Google", size: 300, children: [row("Zebra", size: 200), row("Apple", size: 100)])],
            search: "",
            sort: .name,
            expandedIDs: ["/r/Google"]
        )
        #expect(sorted.map(\.title) == ["Google", "Apple", "Zebra"])
    }

    @Test("Size sort keeps the builder's child order")
    func sizeSortKeepsChildren() {
        #expect(titles(expanded: ["/r/Google"]) == ["Google", "Chrome", "Drive", "Homebrew"])
    }

    // MARK: - Scroll position

    @Test("A reload keeps the scroll position unless the host's token moved")
    func scrollReset() {
        #expect(!ManagerItemTable.shouldResetScroll(previous: "a|size|", current: "a|size|"))
        #expect(ManagerItemTable.shouldResetScroll(previous: "a|size|", current: "b|size|"))
        #expect(ManagerItemTable.shouldResetScroll(previous: nil, current: nil))
    }

    // MARK: - Dashboard

    @Test("Bytes in a group with no card are counted for the caption")
    func unshownBytes() {
        let items = CleanupGroup.allCases
            .flatMap(\.categories)
            .enumerated()
            .map { index, category in
                ScannedFile(
                    url: URL(fileURLWithPath: "/tmp/\(category.rawValue)"),
                    size: Int64(index + 1) * 1_000,
                    lastAccessDate: nil,
                    lastModifiedDate: nil,
                    category: category
                )
            }
        let result = ScanResult(items: items)
        let tiles = CleanupDashboardTile.recommended(from: result)

        #expect(tiles.count == 4)
        let smallestGroup = CleanupGroupTile.tiles(from: result).map(\.totalBytes).min()
        #expect(CleanupDashboardTile.unshownBytes(totalBytes: result.totalSize, tiles: tiles) == smallestGroup)
    }

    @Test("Nothing is unshown when every group has a card")
    func nothingUnshown() {
        let file = ScannedFile(
            url: URL(fileURLWithPath: "/tmp/t"),
            size: 10,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .trash
        )
        let result = ScanResult(items: [file])

        #expect(CleanupDashboardTile.unshownBytes(
            totalBytes: result.totalSize,
            tiles: CleanupDashboardTile.recommended(from: result)
        ) == 0)
    }

    @Test("A huge lone finding isn't backed up by a card saying there's almost no junk")
    func backfillDoesNotContradict() {
        let file = ScannedFile(
            url: URL(fileURLWithPath: "/tmp/t"),
            size: 200_000_000_000,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: .trash
        )

        let tiles = CleanupDashboardTile.recommended(from: ScanResult(items: [file]))

        guard case .reassurance(let filler) = tiles.last else {
            Issue.record("expected a reassurance backfill")
            return
        }
        #expect(filler.id != "cleanup.tidy")
    }
}
