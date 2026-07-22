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

    /// The folder-row checkbox's all-selected answer resolves through the same
    /// row index as `files(forRowID:)` — a folder unions its children — without
    /// materializing the subtree's file array.
    func test_allFilesSelected_forFolderRow_walksDescendants() async {
        let store = CleanupManagerStore()
        let a = file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache)
        let b = file("/Users/me/Library/Caches/Google/Chrome/b", 200, .userCache)
        // A divergent third file keeps the common ancestor at Caches, so Google
        // stays a top-level folder disclosing its Chrome child.
        let c = file("/Users/me/Library/Caches/Homebrew/d", 50, .userCache)
        store.load(result: ScanResult(items: [a, b, c]))
        _ = store.items(forCategoryID: "userCache")

        // The path index warms on a background task; poll for it.
        var google: ManagerItem?
        for _ in 0..<200 {
            google = store.items(forCategoryID: "userCache").first { $0.title == "Google" }
            if store.files(forRowID: google!.id).count == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }

        // Each predicate stands for a different selection, so each carries its
        // own revision — answers are memoized within one.
        let selected: Set<URL> = [a.url, b.url]
        XCTAssertTrue(store.allFilesSelected(forRowID: google!.id, selectionRevision: 1) { selected.contains($0.url) })
        XCTAssertFalse(store.allFilesSelected(forRowID: google!.id, selectionRevision: 2) { $0.url == a.url },
                       "One unselected descendant must uncheck the folder")
        XCTAssertFalse(store.allFilesSelected(forRowID: google!.id, selectionRevision: 3) { _ in false })
    }

    /// Within one selection revision a row is walked once and the answer
    /// reused: an all-selected folder row has nothing to short-circuit on, so
    /// re-walking it every time the table configures its cell is what made
    /// scrolling a huge category (a quarter-million files under `~/.npm`) jerk.
    func test_allFilesSelected_memoizesWithinARevision() async {
        let store = CleanupManagerStore()
        let a = file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache)
        let b = file("/Users/me/Library/Caches/Google/Chrome/b", 200, .userCache)
        let c = file("/Users/me/Library/Caches/Homebrew/d", 50, .userCache)
        store.load(result: ScanResult(items: [a, b, c]))
        var google: ManagerItem?
        for _ in 0..<200 {
            google = store.items(forCategoryID: "userCache").first { $0.title == "Google" }
            if store.files(forRowID: google!.id).count == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }

        var walks = 0
        for _ in 0..<5 {
            _ = store.allFilesSelected(forRowID: google!.id, selectionRevision: 7) { _ in
                walks += 1
                return true
            }
        }

        XCTAssertEqual(walks, 2, "The row's two files must be visited once, not once per query")
    }

    /// A new revision drops the cache: a selection change has to reach the
    /// checkboxes, never a stale answer.
    func test_allFilesSelected_recomputesOnNewRevision() async {
        let store = CleanupManagerStore()
        let a = file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache)
        let b = file("/Users/me/Library/Caches/Google/Chrome/b", 200, .userCache)
        let c = file("/Users/me/Library/Caches/Homebrew/d", 50, .userCache)
        store.load(result: ScanResult(items: [a, b, c]))
        var google: ManagerItem?
        for _ in 0..<200 {
            google = store.items(forCategoryID: "userCache").first { $0.title == "Google" }
            if store.files(forRowID: google!.id).count == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }

        XCTAssertTrue(store.allFilesSelected(forRowID: google!.id, selectionRevision: 1) { _ in true })
        XCTAssertFalse(store.allFilesSelected(forRowID: google!.id, selectionRevision: 2) { _ in false })
        XCTAssertTrue(store.allFilesSelected(forRowID: google!.id, selectionRevision: 3) { _ in true })
    }

    /// A row that resolves to no indexed files — an unknown id, or paths the
    /// background warm hasn't indexed yet — answers unchecked, matching the
    /// empty-array behavior of the materializing path it replaces.
    func test_allFilesSelected_withNoResolvedFiles_isFalse() {
        let store = CleanupManagerStore()
        store.load(result: ScanResult(items: [
            file("/Users/me/Library/Caches/Google/Chrome/a", 300, .userCache),
        ]))
        _ = store.items(forCategoryID: "userCache")

        XCTAssertFalse(store.allFilesSelected(forRowID: "/no/such/row", selectionRevision: 1) { _ in true })
    }

    /// Building Web Development Junk's rows also caches its idle project
    /// artifacts, so the Select menu reads them O(1) instead of rescanning a
    /// third-of-a-million-file category on the main thread. The list is `nil`
    /// until the rows are built, so the menu simply omits the pick until then.
    func test_webDevIdleProjectFiles_populatedByItemsBuild() {
        let store = CleanupManagerStore()
        let now = Date()
        let idle = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Developer/old-app/node_modules"),
            size: 100, lastAccessDate: nil,
            lastModifiedDate: now.addingTimeInterval(-200 * 86_400), category: .webDevJunk
        )
        let fresh = ScannedFile(
            url: URL(fileURLWithPath: "/Users/me/Developer/shipping-app/node_modules"),
            size: 80, lastAccessDate: nil,
            lastModifiedDate: now.addingTimeInterval(-3 * 86_400), category: .webDevJunk
        )
        store.load(result: ScanResult(items: [idle, fresh]))

        // Not computed until the category's rows are built.
        XCTAssertNil(store.webDevIdleProjectFiles())

        _ = store.items(forCategoryID: ScanCategory.webDevJunk.rawValue)

        XCTAssertEqual(
            store.webDevIdleProjectFiles()?.map(\.url.path),
            ["/Users/me/Developer/old-app/node_modules"]
        )

        store.unload()
        XCTAssertNil(store.webDevIdleProjectFiles())
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
