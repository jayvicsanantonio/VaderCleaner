// CleanupManagerStoreTests.swift
// Verifies the Cleanup Manager store serves the shell and per-category trees, indexes row selection paths, and (after its background warm) resolves files by path.

import XCTest
@testable import VaderCleaner

final class CleanupManagerStoreTests: XCTestCase {

    /// `sections()` returns the shell (sizes, no rows) and `items(forCategoryID:)`
    /// returns that category's tree; building a category's items indexes its
    /// rows' selection paths.
    func test_sectionsAndItems_buildAndIndex() {
        let store = CleanupManagerStore()
        store.load(result: ScanResult(items: [
            file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache),
            file("/Users/me/Library/Caches/Homebrew/b", 200, .userCache),
            file("/Users/me/.Trash/old.dmg", 400, .trash),
        ]))

        let shell = store.sections()
        XCTAssertEqual(shell.map(\.id), ["systemJunk", "mailAttachments", "trashBins"])
        let userCaches = shell.first { $0.id == "systemJunk" }?.categories.first { $0.id == "userCache" }
        XCTAssertEqual(userCaches?.totalSize, 500)
        XCTAssertEqual(userCaches?.items.isEmpty, true)

        let rows = store.items(forCategoryID: "userCache")
        XCTAssertEqual(rows.map(\.title).sorted(), ["Google", "Homebrew"])

        // Building the category indexed its rows. A folder row resolves to its
        // descendant leaf paths through the store — the folder item no longer
        // carries the path list itself (the store unions its children).
        let google = rows.first { $0.title == "Google" }!
        XCTAssertTrue(google.isExpandable)
        XCTAssertEqual(
            store.selectionPaths(forRowID: google.id),
            ["/Users/me/Library/Caches/Google/Chrome/a"]
        )
    }

    /// A folder row's covered leaf paths are resolved by unioning its children,
    /// so selecting the folder still selects its whole subtree even though the
    /// item stores no paths of its own.
    func test_selectionPaths_forFolderRow_unionsDescendants() {
        let store = CleanupManagerStore()
        let a = file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache)
        let b = file("/Users/me/Library/Caches/Google/Chrome/b", 200, .userCache)
        let c = file("/Users/me/Library/Caches/Homebrew/d", 50, .userCache)
        store.load(result: ScanResult(items: [a, b, c]))

        let rows = store.items(forCategoryID: "userCache")
        let google = rows.first { $0.title == "Google" }!

        XCTAssertEqual(
            Set(store.selectionPaths(forRowID: google.id)),
            [a.url.path, b.url.path],
            "A folder must resolve to every descendant leaf path"
        )
    }

    /// The whole-subtree file resolution a folder checkbox relies on still works
    /// once the background path index is warm.
    func test_files_forFolderRow_resolveDescendantsAfterWarm() async {
        let store = CleanupManagerStore()
        let a = file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache)
        let b = file("/Users/me/Library/Caches/Google/Chrome/b", 200, .userCache)
        // A divergent third file keeps the common ancestor at Caches, so Google
        // stays a top-level folder disclosing its Chrome child.
        let c = file("/Users/me/Library/Caches/Homebrew/d", 50, .userCache)
        store.load(result: ScanResult(items: [a, b, c]))
        _ = store.items(forCategoryID: "userCache")

        // The path index warms on a background task; poll for it.
        var resolved: [ScannedFile] = []
        for _ in 0..<200 {
            let google = store.items(forCategoryID: "userCache").first { $0.title == "Google" }!
            resolved = store.files(forRowID: google.id)
            if resolved.count == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
        XCTAssertEqual(Set(resolved), [a, b])
    }

    /// The background warm builds the path→file index; poll briefly for it.
    func test_fileByPath_resolvesAfterWarm() async {
        let store = CleanupManagerStore()
        let target = file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache)
        store.load(result: ScanResult(items: [target]))

        var resolved: ScannedFile?
        for _ in 0..<200 {
            if let found = store.file(forPath: target.url.path) { resolved = found; break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
        XCTAssertEqual(resolved, target)
    }

    /// `unload()` drops everything the store serves: category trees come back
    /// empty and the path index no longer resolves files — even if the
    /// superseded load's background warm lands after the unload.
    func test_unload_dropsServedContent() async {
        let store = CleanupManagerStore()
        let target = file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache)
        store.load(result: ScanResult(items: [target]))
        XCTAssertFalse(store.items(forCategoryID: "userCache").isEmpty)

        store.unload()

        XCTAssertTrue(store.items(forCategoryID: "userCache").isEmpty)
        // The unload bumps the load token, so the earlier load's background
        // warm must be dropped rather than repopulating the path index; give
        // it a beat to land before asserting.
        try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        XCTAssertNil(store.file(forPath: target.url.path))
    }

    private func file(_ path: String, _ size: Int64, _ category: ScanCategory) -> ScannedFile {
        ScannedFile(url: URL(fileURLWithPath: path), size: size, lastAccessDate: nil, lastModifiedDate: nil, category: category)
    }
}
