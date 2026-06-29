// SpaceLensChildrenTests.swift
// Verifies the Space Lens display-row builder: zero-byte children dropped, largest-first ordering, and the "Other items" aggregate folding the long tail.

import XCTest
@testable import VaderCleaner

final class SpaceLensChildrenTests: XCTestCase {

    private func file(_ name: String, _ size: Int64) -> DiskNode {
        DiskNode(url: URL(fileURLWithPath: "/root/\(name)"), name: name,
                 size: size, isDirectory: false, children: [], itemCount: 0)
    }

    private func node(_ children: [DiskNode]) -> DiskNode {
        DiskNode(url: URL(fileURLWithPath: "/root"), name: "root",
                 size: children.reduce(0) { $0 + $1.size }, isDirectory: true,
                 children: children, itemCount: children.count)
    }

    func test_displayed_includesZeroByteChildrenSortedBySize() {
        // Zero-byte children (e.g. .localized) are shown too, sorted last.
        let tree = node([file("a", 10), file("empty", 0), file("b", 100)])
        let rows = SpaceLensChildren.displayed(for: tree)
        XCTAssertEqual(rows.map(\.name), ["b", "a", "empty"])
    }

    func test_displayed_underLimit_showsAllIndividually() {
        let tree = node([file("a", 30), file("b", 20), file("c", 10)])
        let rows = SpaceLensChildren.displayed(for: tree, maxRows: 8)
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(rows.contains { $0.isOther })
    }

    func test_displayed_overLimit_foldsTailIntoOtherItems() {
        // 10 children, maxRows 4 → 3 individual + Other items.
        let children = (1...10).map { file("f\($0)", Int64(100 - $0 * 5)) }
        let tree = node(children)
        let rows = SpaceLensChildren.displayed(for: tree, maxRows: 4)

        XCTAssertEqual(rows.count, 4)
        let other = try? XCTUnwrap(rows.last)
        XCTAssertEqual(other?.isOther, true)
        // Aggregate folds the 7 smallest children.
        XCTAssertEqual(other?.aggregatedChildren.count, 7)
        // Its size is the sum of the folded children.
        let expected = children.sorted { $0.size > $1.size }.suffix(7).reduce(Int64(0)) { $0 + $1.size }
        XCTAssertEqual(other?.size, expected)
    }
}
