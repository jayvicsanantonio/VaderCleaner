// ManagerContentTokenTests.swift
// Pins the ManagerItemTable content-token builder: any change to the displayed rows, their order, the sort, or the search must yield a different token so the table bridge reloads.

import XCTest
@testable import VaderCleaner

final class ManagerContentTokenTests: XCTestCase {

    private func item(_ id: String) -> ManagerItem {
        ManagerItem(
            id: id,
            title: id,
            subtitle: nil,
            size: nil,
            sizeText: nil,
            systemImage: "doc",
            tint: .secondary
        )
    }

    func test_sameRowsProduceSameToken() {
        let items = [item("a"), item("b"), item("c")]

        XCTAssertEqual(
            ManagerItemTable.contentToken(items: items, sort: "size", search: ""),
            ManagerItemTable.contentToken(items: items, sort: "size", search: "")
        )
    }

    func test_middleRowChangeChangesToken_evenWithSameCountAndEndpoints() {
        // Same count, same first id, same last id — only the middle differs.
        // The old count|first|last heuristic could not tell these apart.
        let before = [item("a"), item("m1"), item("z")]
        let after = [item("a"), item("m2"), item("z")]

        XCTAssertNotEqual(
            ManagerItemTable.contentToken(items: before, sort: "size", search: ""),
            ManagerItemTable.contentToken(items: after, sort: "size", search: "")
        )
    }

    func test_rowOrderChangesToken() {
        let forward = [item("a"), item("b")]
        let reversed = [item("b"), item("a")]

        XCTAssertNotEqual(
            ManagerItemTable.contentToken(items: forward, sort: "size", search: ""),
            ManagerItemTable.contentToken(items: reversed, sort: "size", search: "")
        )
    }

    func test_sortAndSearchChangeToken() {
        let items = [item("a")]

        XCTAssertNotEqual(
            ManagerItemTable.contentToken(items: items, sort: "size", search: ""),
            ManagerItemTable.contentToken(items: items, sort: "name", search: "")
        )
        XCTAssertNotEqual(
            ManagerItemTable.contentToken(items: items, sort: "size", search: ""),
            ManagerItemTable.contentToken(items: items, sort: "size", search: "q")
        )
    }

    // MARK: - Selection-refresh gate

    func test_selectionRefresh_withNoToken_alwaysRefreshes() {
        // The flat managers (every Review except Cleanup) supply no revision;
        // their checkbox image tracks `isSelected`, so each update must refresh
        // or a toggle wouldn't repaint the box.
        XCTAssertTrue(ManagerItemTable.shouldRefreshSelection(previous: nil, current: nil))
        XCTAssertTrue(ManagerItemTable.shouldRefreshSelection(previous: 3, current: nil))
    }

    func test_selectionRefresh_withToken_onlyWhenItMoves() {
        // The Cleanup Manager passes a revision so it repaints only on real
        // selection changes — not on the incidental updates during a scroll.
        XCTAssertFalse(ManagerItemTable.shouldRefreshSelection(previous: 5, current: 5))
        XCTAssertTrue(ManagerItemTable.shouldRefreshSelection(previous: 5, current: 6))
        XCTAssertTrue(ManagerItemTable.shouldRefreshSelection(previous: nil, current: 1))
    }
}
