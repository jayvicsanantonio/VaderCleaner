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

    /// Deep-link section lookup resolves the left-pane section that owns a
    /// category — Xcode Junk / Document Versions live under System Junk.
    func test_sectionID_containingCategory() {
        XCTAssertEqual(CleanupManagerModel.sectionID(containing: .xcodeJunk), "systemJunk")
        XCTAssertEqual(CleanupManagerModel.sectionID(containing: .documentVersions), "systemJunk")
        XCTAssertEqual(CleanupManagerModel.sectionID(containing: .userCache), "systemJunk")
        XCTAssertEqual(CleanupManagerModel.sectionID(containing: .trash), "trashBins")
        XCTAssertEqual(CleanupManagerModel.sectionID(containing: .mailAttachments), "mailAttachments")
        XCTAssertNil(CleanupManagerModel.sectionID(containing: .largeFile))
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

    /// A file's path is stored once, not duplicated at every ancestor level: an
    /// expandable folder node delegates its covered paths to its children (the
    /// store unions them on demand), while a childless node carries the paths it
    /// covers directly. This keeps a deep tree over hundreds of thousands of
    /// files from holding each path once per ancestor.
    func test_buildHierarchy_folderNodesDelegatePathsToChildren() {
        // A second top-level folder keeps the common ancestor at Caches, so
        // Google stays a folder node disclosing its Chrome child.
        let files = [
            file("/Users/me/Library/Caches/Google/Chrome/a", 1, .userCache),
            file("/Users/me/Library/Caches/Google/Chrome/b", 1, .userCache),
            file("/Users/me/Library/Caches/Homebrew/d", 1, .userCache),
        ]

        let google = CleanupManagerModel.buildHierarchy(files).first { $0.title == "Google" }!

        // The expandable folder does not copy its descendants' paths.
        XCTAssertTrue(google.isExpandable)
        XCTAssertTrue(
            google.selectionPaths.isEmpty,
            "An expandable folder must delegate its covered paths to its children rather than copy them"
        )

        // Its childless child carries the paths it covers.
        let chrome = google.children.first { $0.title == "Chrome" }!
        XCTAssertTrue(chrome.children.isEmpty)
        XCTAssertEqual(
            Set(chrome.selectionPaths),
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

    // MARK: - Shell vs. items (lazy build)

    /// The shell carries each category's size/badge but no rows, so the panes
    /// can paint before any file tree is built.
    func test_buildShell_hasSizesButNoItems() {
        let result = ScanResult(items: [
            file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache),
            file("/Users/me/Library/Caches/Homebrew/b", 200, .userCache),
        ])

        let shell = CleanupManagerModel.buildShell(
            itemsByCategory: result.itemsByCategory,
            sizeByCategory: result.sizeByCategory,
            includeEmptySections: true
        )

        let userCaches = shell.first { $0.id == "systemJunk" }?.categories.first { $0.id == "userCache" }
        XCTAssertNotNil(userCaches)
        XCTAssertTrue(userCaches!.items.isEmpty, "Shell categories must carry no rows")
        XCTAssertEqual(userCaches!.totalSize, 500)
    }

    /// The per-category builder returns the same tree the full build would.
    func test_items_forCategory_matchesHierarchy() {
        let files = [
            file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache),
            file("/Users/me/Library/Caches/Homebrew/b", 200, .userCache),
        ]
        let result = ScanResult(items: files)

        let lazy = CleanupManagerModel.items(forCategory: .userCache, in: result.itemsByCategory)
        let eager = CleanupManagerModel.buildHierarchy(files)

        XCTAssertEqual(lazy.map(\.id), eager.map(\.id))
        XCTAssertEqual(lazy.map(\.size), eager.map(\.size))
    }

    // MARK: - Web Development Junk rows

    /// Package caches keep the folder tree (`~/.npm` is one row, not its
    /// hundreds of thousands of files) while each project artifact folder gets
    /// its own row naming the project it belongs to — the row is the unit that
    /// gets deleted, so it has to say so rather than hide two disclosures deep.
    func test_webDevItems_cachesStayFoldedAndProjectsAreNamedRows() {
        let files = [
            file("/Users/me/.npm/_cacache/a", 300, .webDevJunk),
            file("/Users/me/.pnpm-store/v3/b", 200, .webDevJunk),
            file("/Users/me/Developer/pixel-prompt/node_modules", 100, .webDevJunk),
            file("/Users/me/Developer/uigen/dist", 50, .webDevJunk),
        ]

        let items = CleanupManagerModel.webDevItems(
            files,
            cacheRoots: ["/Users/me/.npm", "/Users/me/.pnpm-store"]
        )

        XCTAssertEqual(
            items.map(\.title),
            [".npm", ".pnpm-store", "pixel-prompt / node_modules", "uigen / dist"]
        )
        // The cache half keeps its expandable folder node.
        XCTAssertEqual(items[0].size, 300)
        XCTAssertTrue(items[0].isExpandable)
        // Each project artifact is a self-contained row: no disclosure, and it
        // carries exactly the one path deleting it removes.
        let project = items[2]
        XCTAssertFalse(project.isExpandable)
        XCTAssertEqual(project.selectionPaths, ["/Users/me/Developer/pixel-prompt/node_modules"])
        XCTAssertEqual(project.subtitle, "/Users/me/Developer/pixel-prompt")
    }

    /// The category-aware builder routes Web Development Junk to the project
    /// rows and leaves every other category on the folder hierarchy.
    func test_buildItems_routesWebDevJunkOnly() {
        let webDev = [file("/Users/me/Developer/pixel-prompt/node_modules", 100, .webDevJunk)]
        let caches = [file("/Users/me/Library/Caches/Google/Chrome/a", 100, .userCache)]

        XCTAssertEqual(
            CleanupManagerModel.buildItems(for: .webDevJunk, files: webDev, cacheRoots: []).map(\.title),
            ["pixel-prompt / node_modules"]
        )
        XCTAssertEqual(
            CleanupManagerModel.buildItems(for: .userCache, files: caches, cacheRoots: []).map(\.title),
            CleanupManagerModel.buildHierarchy(caches).map(\.title)
        )
    }

    // MARK: - Bulk-select filters

    /// Web Development Junk offers an idle-projects pick that selects exactly
    /// the long-untouched project artifacts and clears everything else — the
    /// one bulk action a user can take without weighing each project.
    func test_selectFilters_idleProjectsClearsThenSelectsIdle() {
        let idle = artifact("/Users/me/Developer/old-app/node_modules", 100, ageDays: 200, now: Date())
        var clears = 0
        var selectedPaths: [String]?

        let filters = CleanupManagerModel.selectFilters(
            forCategoryID: ScanCategory.webDevJunk.rawValue,
            idleProjectFiles: [idle],
            clearAll: { clears += 1 },
            selectIdle: { files in selectedPaths = files.map(\.url.path) }
        )

        XCTAssertEqual(filters.count, 1)
        filters[0].apply()

        // Clear the category first, then check exactly the idle artifacts, so
        // the pick is an exact selection rather than an addition to whatever
        // was already checked.
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(selectedPaths, ["/Users/me/Developer/old-app/node_modules"])
    }

    /// No idle projects, no pick: an option that would select nothing is worse
    /// than no option at all.
    func test_selectFilters_absentWhenNothingIsIdle() {
        let filters = CleanupManagerModel.selectFilters(
            forCategoryID: ScanCategory.webDevJunk.rawValue,
            idleProjectFiles: [],
            clearAll: {},
            selectIdle: { _ in }
        )

        XCTAssertTrue(filters.isEmpty)
    }

    /// Other categories get no extra picks — the filter is specific to the
    /// project-artifact problem, not a general manager feature.
    func test_selectFilters_absentForOtherCategories() {
        let idle = artifact("/Users/me/Developer/old-app/node_modules", 100, ageDays: 200, now: Date())
        let filters = CleanupManagerModel.selectFilters(
            forCategoryID: ScanCategory.userCache.rawValue,
            idleProjectFiles: [idle],
            clearAll: {},
            selectIdle: { _ in }
        )

        XCTAssertTrue(filters.isEmpty)
    }

    /// The single-pass content builder both names the project rows and
    /// identifies the idle artifacts, so the store computes both off-main in one
    /// walk instead of rescanning the category on the main thread.
    func test_webDevContent_returnsRowsAndIdleProjectsInOnePass() {
        let now = Date(timeIntervalSince1970: 400 * 86_400)
        let old = artifact("/Users/me/Developer/old-app/node_modules", 100, ageDays: 200, now: now)
        let fresh = artifact("/Users/me/Developer/shipping-app/node_modules", 80, ageDays: 3, now: now)
        let cache = file("/Users/me/.npm/_cacache/a", 300, .webDevJunk)

        let content = CleanupManagerModel.webDevContent(
            [old, fresh, cache],
            now: now,
            cacheRoots: ["/Users/me/.npm"]
        )

        // Rows: the cache folds into a folder tree; both projects are named rows.
        XCTAssertTrue(content.items.contains { $0.title == "old-app / node_modules" })
        XCTAssertTrue(content.items.contains { $0.title == "shipping-app / node_modules" })
        // Idle list: only the long-untouched project, never a cache file.
        XCTAssertEqual(content.idleProjectFiles.map(\.url.path), ["/Users/me/Developer/old-app/node_modules"])
    }

    // MARK: - Pane descriptions

    /// Sections and categories carry the header descriptions the panes show.
    func test_descriptions_areProvided() {
        XCTAssertNotNil(CleanupManagerModel.sectionDescription(forID: "systemJunk"))
        XCTAssertNotNil(CleanupManagerModel.sectionDescription(forID: "mailAttachments"))
        XCTAssertNotNil(CleanupManagerModel.sectionDescription(forID: "trashBins"))
        XCTAssertNil(CleanupManagerModel.sectionDescription(forID: "unknown"))

        XCTAssertNotNil(CleanupManagerModel.categoryDescription(for: .userCache))
        XCTAssertNotNil(CleanupManagerModel.categoryDescription(for: .xcodeJunk))
        XCTAssertNil(CleanupManagerModel.categoryDescription(for: .largeFile))
    }

    /// The shell threads the descriptions onto its sections and categories.
    func test_buildShell_carriesDescriptions() {
        let result = ScanResult(items: [file("/Users/me/Library/Caches/Google/a", 1, .userCache)])
        let shell = CleanupManagerModel.buildShell(
            itemsByCategory: result.itemsByCategory,
            sizeByCategory: result.sizeByCategory,
            includeEmptySections: true
        )
        let systemJunk = shell.first { $0.id == "systemJunk" }
        XCTAssertEqual(systemJunk?.description, CleanupManagerModel.sectionDescription(forID: "systemJunk"))
        let userCaches = systemJunk?.categories.first { $0.id == "userCache" }
        XCTAssertEqual(userCaches?.description, CleanupManagerModel.categoryDescription(for: .userCache))
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

    /// A project artifact last modified `ageDays` before `now`.
    private func artifact(_ path: String, _ size: Int64, ageDays: Double, now: Date) -> ScannedFile {
        ScannedFile(
            url: URL(fileURLWithPath: path),
            size: size,
            lastAccessDate: nil,
            lastModifiedDate: now.addingTimeInterval(-ageDays * 86_400),
            category: .webDevJunk
        )
    }
}
