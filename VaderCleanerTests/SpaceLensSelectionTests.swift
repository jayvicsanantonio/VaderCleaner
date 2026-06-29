// SpaceLensSelectionTests.swift
// Verifies Space Lens selection: toggling, bulk select/deselect, deduped nested totals, and the top-level selected-node list the review sheet uses.

import XCTest
@testable import VaderCleaner

@MainActor
final class SpaceLensSelectionTests: XCTestCase {

    // /root → [docs/ (size 300, itemCount 2 → [a (100), b (200)]), big (500)]
    private func sampleTree() -> DiskNode {
        let a = DiskNode(url: URL(fileURLWithPath: "/root/docs/a"), name: "a", size: 100, isDirectory: false, children: [], itemCount: 0)
        let b = DiskNode(url: URL(fileURLWithPath: "/root/docs/b"), name: "b", size: 200, isDirectory: false, children: [], itemCount: 0)
        let docs = DiskNode(url: URL(fileURLWithPath: "/root/docs"), name: "docs", size: 300, isDirectory: true, children: [a, b], itemCount: 2)
        let big = DiskNode(url: URL(fileURLWithPath: "/root/big"), name: "big", size: 500, isDirectory: false, children: [], itemCount: 0)
        return DiskNode(url: URL(fileURLWithPath: "/root"), name: "root", size: 800, isDirectory: true, children: [docs, big], itemCount: 4)
    }

    func test_toggle_addsThenRemoves() {
        let tree = sampleTree()
        let big = tree.children.first { $0.name == "big" }!
        let selection = SpaceLensSelection()

        selection.toggle(big)
        XCTAssertTrue(selection.isSelected(big))
        selection.toggle(big)
        XCTAssertFalse(selection.isSelected(big))
        XCTAssertTrue(selection.isEmpty)
    }

    func test_totals_sumSizeAndItemCount() {
        let tree = sampleTree()
        let docs = tree.children.first { $0.name == "docs" }!
        let selection = SpaceLensSelection()

        selection.toggle(docs) // folder reports its contained items: itemCount 2
        let totals = selection.totals
        XCTAssertEqual(totals.size, 300)
        XCTAssertEqual(totals.count, 2)
    }

    func test_totals_dedupeNestedSelection() {
        let tree = sampleTree()
        let docs = tree.children.first { $0.name == "docs" }!
        let a = docs.children.first { $0.name == "a" }!
        let selection = SpaceLensSelection()

        // Selecting both a folder and a file inside it must count only the folder.
        selection.select([docs, a])
        let totals = selection.totals
        XCTAssertEqual(totals.size, 300)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(selection.selectedNodes().map(\.name), ["docs"])
    }

    func test_selectedNodes_returnsTopLevelSelections() {
        let tree = sampleTree()
        let docs = tree.children.first { $0.name == "docs" }!
        let big = tree.children.first { $0.name == "big" }!
        let selection = SpaceLensSelection()

        selection.select([docs, big])
        XCTAssertEqual(Set(selection.selectedNodes().map(\.name)), ["docs", "big"])
    }

    func test_deselectAndClear() {
        let tree = sampleTree()
        let docs = tree.children.first { $0.name == "docs" }!
        let big = tree.children.first { $0.name == "big" }!
        let selection = SpaceLensSelection()

        selection.select([docs, big])
        selection.deselect([docs])
        XCTAssertEqual(selection.selectedNodes().map(\.name), ["big"])
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
    }
}
