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

        // Building the category indexed its rows' selection paths.
        let google = rows.first { $0.title == "Google" }!
        XCTAssertEqual(store.selectionPaths(forRowID: google.id), google.selectionPaths)
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

    private func file(_ path: String, _ size: Int64, _ category: ScanCategory) -> ScannedFile {
        ScannedFile(url: URL(fileURLWithPath: path), size: size, lastAccessDate: nil, lastModifiedDate: nil, category: category)
    }
}
