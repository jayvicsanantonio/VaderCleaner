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

    // MARK: - itemCount rollup

    /// A directory's `itemCount` is the number of descendants beneath it —
    /// every file and subfolder, recursively. A leaf file has no descendants,
    /// so its own `itemCount` is 0; a parent counts each child as `1 + the
    /// child's own itemCount`. Drives the "N items" labels and the
    /// selected-items counter.
    func test_itemCount_countsAllDescendants() {
        let leafB = DiskNode(
            url: URL(fileURLWithPath: "/tmp/nested/b.bin"),
            name: "b.bin", size: 64, isDirectory: false, children: [], itemCount: 0
        )
        let nestedDir = DiskNode(
            url: URL(fileURLWithPath: "/tmp/nested"),
            name: "nested", size: 64, isDirectory: true, children: [leafB], itemCount: 1
        )
        let leafA = DiskNode(
            url: URL(fileURLWithPath: "/tmp/a.bin"),
            name: "a.bin", size: 32, isDirectory: false, children: [], itemCount: 0
        )
        // tmp holds a.bin (1), nested (1) and nested/b.bin (1) = 3 descendants.
        let parent = DiskNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp", size: 96, isDirectory: true, children: [leafA, nestedDir], itemCount: 3
        )

        XCTAssertEqual(leafA.itemCount, 0)
        XCTAssertEqual(nestedDir.itemCount, 1)
        XCTAssertEqual(parent.itemCount, 3)
    }

    // MARK: - removing(ids:)

    /// Pruning a child subtree returns a new tree with that subtree gone and
    /// the ancestor's `size` and `itemCount` rolled back down — so the view
    /// reflects a Trash removal without a full re-scan.
    func test_removing_dropsSubtreeAndRollsUpSizeAndCount() {
        let tree = Self.sampleTree()
        let nested = tree.children.first { $0.name == "nested" }!

        let pruned = tree.removing([nested.id])

        XCTAssertEqual(pruned.children.map(\.name), ["a.bin"])
        XCTAssertEqual(pruned.size, 32)        // only a.bin remains
        XCTAssertEqual(pruned.itemCount, 1)    // only a.bin remains
    }

    /// Removing a node nested several levels deep recomputes every ancestor on
    /// the path, not just the immediate parent.
    func test_removing_recomputesDeepAncestors() {
        let tree = Self.sampleTree()
        let nested = tree.children.first { $0.name == "nested" }!
        let deepLeaf = nested.children.first { $0.name == "b.bin" }!

        let pruned = tree.removing([deepLeaf.id])
        let prunedNested = pruned.children.first { $0.name == "nested" }!

        XCTAssertTrue(prunedNested.children.isEmpty)
        XCTAssertEqual(prunedNested.size, 0)
        XCTAssertEqual(prunedNested.itemCount, 0)
        XCTAssertEqual(pruned.size, 32)        // a.bin (32) + now-empty nested (0)
        XCTAssertEqual(pruned.itemCount, 2)    // a.bin + the empty nested folder
    }

    /// Survivors keep their stable `id` so the breadcrumb path can be remapped
    /// onto the pruned tree after a removal.
    func test_removing_preservesSurvivorIdentity() {
        let tree = Self.sampleTree()
        let leafA = tree.children.first { $0.name == "a.bin" }!
        let nested = tree.children.first { $0.name == "nested" }!

        let pruned = tree.removing([nested.id])

        XCTAssertEqual(pruned.id, tree.id)
        XCTAssertEqual(pruned.children.first?.id, leafA.id)
    }

    /// An id that isn't anywhere in the tree leaves it untouched.
    func test_removing_unknownId_isNoOp() {
        let tree = Self.sampleTree()
        let pruned = tree.removing([UUID()])

        XCTAssertEqual(pruned.children.map(\.name), tree.children.map(\.name))
        XCTAssertEqual(pruned.size, tree.size)
        XCTAssertEqual(pruned.itemCount, tree.itemCount)
    }

    /// `/tmp` → [a.bin (32), nested/ → [b.bin (64)]]. size 96, itemCount 3.
    private static func sampleTree() -> DiskNode {
        let leafB = DiskNode(
            url: URL(fileURLWithPath: "/tmp/nested/b.bin"),
            name: "b.bin", size: 64, isDirectory: false, children: [], itemCount: 0
        )
        let nestedDir = DiskNode(
            url: URL(fileURLWithPath: "/tmp/nested"),
            name: "nested", size: 64, isDirectory: true, children: [leafB], itemCount: 1
        )
        let leafA = DiskNode(
            url: URL(fileURLWithPath: "/tmp/a.bin"),
            name: "a.bin", size: 32, isDirectory: false, children: [], itemCount: 0
        )
        return DiskNode(
            url: URL(fileURLWithPath: "/tmp"),
            name: "tmp", size: 96, isDirectory: true, children: [leafA, nestedDir], itemCount: 3
        )
    }
}
