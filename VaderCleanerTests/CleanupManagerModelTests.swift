// CleanupManagerModelTests.swift
// Pins the Cleanup Manager section builder: the System Junk umbrella grouping and the one-level folder hierarchy (top-level folders, their children, aggregated sizes, and selection paths).

import XCTest
@testable import VaderCleaner

final class CleanupManagerModelTests: XCTestCase {

    // MARK: - Grouping

    /// Xcode Junk and Document Versions live under the System Junk umbrella in
    /// the manager, not as their own left-pane sections.
    func test_groups_systemJunkUmbrellaContainsDeveloperCategories() {
        let systemJunk = CleanupManagerModel.groups.first { $0.id == "systemJunk" }
        XCTAssertNotNil(systemJunk)
        XCTAssertTrue(systemJunk!.categories.contains(.userCache))
        XCTAssertTrue(systemJunk!.categories.contains(.xcodeJunk))
        XCTAssertTrue(systemJunk!.categories.contains(.documentVersions))
        XCTAssertTrue(systemJunk!.categories.contains(.userLogs))
    }

    func test_groups_areSystemJunkMailTrash() {
        XCTAssertEqual(CleanupManagerModel.groups.map(\.id), ["systemJunk", "mailAttachments", "trashBins"])
    }

    // MARK: - Empty sections

    /// The standalone manager always lists the three sections, even when a
    /// section has no findings; Smart Scan drops empty ones.
    func test_build_includeEmptySections_keepsAllThreeSections() {
        let result = ScanResult(items: [file("/Users/me/Library/Caches/Google/Chrome/a", 100, .userCache)])

        let withEmpty = CleanupManagerModel.build(
            itemsByCategory: result.itemsByCategory,
            sizeByCategory: result.sizeByCategory,
            includeEmptySections: true,
            hierarchical: true
        )
        XCTAssertEqual(withEmpty.map(\.id), ["systemJunk", "mailAttachments", "trashBins"])

        let withoutEmpty = CleanupManagerModel.build(
            itemsByCategory: result.itemsByCategory,
            sizeByCategory: result.sizeByCategory,
            includeEmptySections: false,
            hierarchical: true
        )
        XCTAssertEqual(withoutEmpty.map(\.id), ["systemJunk"])
    }

    // MARK: - Hierarchy

    /// Files under a common ancestor fold into top-level folders, each
    /// disclosing one level of children, with sizes aggregated up the tree.
    func test_buildHierarchy_topLevelFoldersWithChildrenAndAggregatedSizes() {
        let files = [
            file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache),
            file("/Users/me/Library/Caches/Google/Chrome/b", 200, .userCache),
            file("/Users/me/Library/Caches/Google/ChromeDev/c", 100, .userCache),
            file("/Users/me/Library/Caches/Homebrew/d", 50, .userCache),
        ]

        let items = CleanupManagerModel.buildHierarchy(files)

        // Top level: Google (600) and Homebrew (50), size-sorted.
        XCTAssertEqual(items.map(\.title), ["Google", "Homebrew"])
        XCTAssertEqual(items[0].size, 600)
        XCTAssertEqual(items[1].size, 50)

        // Google discloses Chrome (500) and ChromeDev (100).
        let google = items[0]
        XCTAssertTrue(google.isExpandable)
        XCTAssertEqual(google.children.map(\.title), ["Chrome", "ChromeDev"])
        XCTAssertEqual(google.children[0].size, 500)
        XCTAssertEqual(google.children[0].indentLevel, 1)

        // Children are leaves — one level of expansion only.
        XCTAssertTrue(google.children.allSatisfy { !$0.isExpandable })
    }

    /// A folder node's selectionPaths cover every leaf file beneath it, so its
    /// checkbox can select the whole subtree.
    func test_buildHierarchy_selectionPathsCoverAllDescendants() {
        // A second top-level folder keeps the common ancestor at Caches, so
        // Google stays a folder node aggregating its two files.
        let files = [
            file("/Users/me/Library/Caches/Google/Chrome/a", 1, .userCache),
            file("/Users/me/Library/Caches/Google/Chrome/b", 1, .userCache),
            file("/Users/me/Library/Caches/Homebrew/d", 1, .userCache),
        ]

        let google = CleanupManagerModel.buildHierarchy(files).first { $0.title == "Google" }!

        XCTAssertEqual(
            Set(google.selectionPaths),
            ["/Users/me/Library/Caches/Google/Chrome/a", "/Users/me/Library/Caches/Google/Chrome/b"]
        )
    }

    /// A single file directly under the common ancestor is a leaf row with no
    /// chevron.
    func test_buildHierarchy_directFileIsLeaf() {
        let files = [
            file("/Users/me/Library/Caches/Google/a", 100, .userCache),
            file("/Users/me/Library/Caches/loosefile", 50, .userCache),
        ]

        let items = CleanupManagerModel.buildHierarchy(files)

        let loose = items.first { $0.title == "loosefile" }
        XCTAssertNotNil(loose)
        XCTAssertFalse(loose!.isExpandable)
    }

    // MARK: - Helpers

    private func file(_ path: String, _ size: Int64, _ category: ScanCategory) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: nil,
            category: category
        )
    }
}
