// DiskNodeTests.swift
// Locks DiskNode's directory size = sum of children invariant and the percent-of-parent helper, including the parent-size-zero guard.

import XCTest
@testable import VaderCleaner

/// Unit tests for `DiskNode`. The node type is pure data — it does no I/O —
/// so these tests build trees by hand. Disk-walking behaviour lives in
/// `DiskScannerTests`.
final class DiskNodeTests: XCTestCase {

    // MARK: - Size rollup

    /// A directory's `size` must equal the sum of its children's sizes,
    /// recursively. The treemap UI in Prompt 17 reads this rolled-up value
    /// to size each tile, so any drift between the stored size and the
    /// actual contents would render the visualization wrong.
    func test_size_isSumOfChildrenForDirectory() {
        let leafA = DiskNode(
            url: URL(fileURLWithPath: "/tmp/a.bin"),
            name: "a.bin",
            size: 32,
            isDirectory: false,
            children: []
        )
        let leafB = DiskNode(
            url: URL(fileURLWithPath: "/tmp/b.bin"),
            name: "b.bin",
            size: 64,
            isDirectory: false,
            children: []
        )
        let nestedDir = DiskNode(
            url: URL(fileURLWithPath: "/tmp/nested"),
            name: "nested",
            size: 64,
            isDirectory: true,
            children: [leafB]
        )
        let parent = DiskNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            size: 96, // 32 + 64
            isDirectory: true,
            children: [leafA, nestedDir]
        )

        XCTAssertEqual(parent.size, leafA.size + nestedDir.size)
        XCTAssertEqual(nestedDir.size, leafB.size)
    }

    // MARK: - percentOfParent

    /// `percentOfParent` returns the child's share of the parent as a value
    /// in [0, 1]. Used by the treemap to decide which tiles are visible at
    /// a given zoom level.
    func test_percentOfParent_returnsRatioOfChildToParent() {
        let parent = DiskNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp",
            size: 1000,
            isDirectory: true,
            children: []
        )
        let child = DiskNode(
            url: URL(fileURLWithPath: "/tmp/a.bin"),
            name: "a.bin",
            size: 250,
            isDirectory: false,
            children: []
        )

        XCTAssertEqual(child.percentOfParent(parent), 0.25, accuracy: 0.0001)
    }

    /// When the parent reports zero bytes, the ratio is undefined; the
    /// helper must return 0 rather than divide-by-zero. Empty directories
    /// (no contents) hit this naturally and would otherwise crash the UI.
    func test_percentOfParent_returnsZeroWhenParentSizeIsZero() {
        let parent = DiskNode(
            url: URL(fileURLWithPath: "/tmp/empty"),
            name: "empty",
            size: 0,
            isDirectory: true,
            children: []
        )
        let child = DiskNode(
            url: URL(fileURLWithPath: "/tmp/empty/a.bin"),
            name: "a.bin",
            size: 0,
            isDirectory: false,
            children: []
        )

        XCTAssertEqual(child.percentOfParent(parent), 0)
    }
}
