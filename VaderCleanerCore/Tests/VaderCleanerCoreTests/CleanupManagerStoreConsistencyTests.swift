// CleanupManagerStoreConsistencyTests.swift
// Pins the Cleanup Manager store against its timing and coverage edges: rows never outrun the path index, a stale build can't repopulate the store, and a row's checkbox reflects everything the row's size counts.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite("Cleanup Manager store consistency")
struct CleanupManagerStoreConsistencyTests {

    private func file(_ path: String, _ size: Int64, _ category: ScanCategory) -> ScannedFile {
        ScannedFile(url: URL(fileURLWithPath: path), size: size, lastAccessDate: nil, lastModifiedDate: nil, category: category)
    }

    /// A small category plus a large one that keeps the low-priority warm busy.
    private func storeWithSlowWarm() -> (store: CleanupManagerStore, target: ScannedFile) {
        let target = file("/Users/me/.Trash/old.dmg", 100, .trash)
        var items = [target]
        items.append(contentsOf: (0..<300_000).map { file("/Users/me/Library/Caches/app/\($0)", 1, .userCache) })
        let store = CleanupManagerStore()
        store.load(result: ScanResult(items: items))
        return (store, target)
    }

    @Test("A row's files resolve as soon as its rows exist, however busy the warm is")
    func rowsNeverOutrunTheIndex() {
        let (store, target) = storeWithSlowWarm()

        _ = store.items(forCategoryID: "trash")

        #expect(store.files(forRowID: target.url.path) == [target])
    }

    @Test("A checkbox answer can't go stale behind the index")
    func answersReflectTheIndex() {
        let (store, target) = storeWithSlowWarm()

        _ = store.items(forCategoryID: "trash")

        #expect(store.allFilesSelected(forRowID: target.url.path, selectionRevision: 1) { _ in true })
    }

    @Test("A tree build in flight during unload doesn't repopulate the store")
    func staleBuildStaysOut() async {
        let store = CleanupManagerStore()
        let items = (0..<300_000).map { file("/Users/me/Library/Caches/app\($0 % 500)/\($0)", 1, .userCache) }
        store.load(result: ScanResult(items: items))

        let build = Task.detached(priority: .userInitiated) { store.items(forCategoryID: "userCache") }
        try? await Task.sleep(for: .milliseconds(20))
        store.unload()
        _ = await build.value

        #expect(store.items(forCategoryID: "userCache").isEmpty)
    }

    @Test("A folder row's checkbox covers a scanned file that is the folder itself")
    func rowCoversItsOwnRolledUpFile() throws {
        let store = CleanupManagerStore()
        let folder = file("/R/pkg", 100, .userCache)
        let inner = file("/R/pkg/inner", 50, .userCache)
        store.load(result: ScanResult(items: [folder, inner, file("/R/z", 10, .userCache)]))

        let rows = store.items(forCategoryID: "userCache")
        let row = try #require(rows.first { $0.id == folder.url.path })

        #expect(row.size == 150)
        #expect(row.isExpandable)
        #expect(Set(store.files(forRowID: row.id)) == [folder, inner])
        #expect(!store.allFilesSelected(forRowID: row.id, selectionRevision: 1) { $0 == inner })
    }

    @Test("A row reports none, some, or all of what it covers")
    func rowSelectionStates() throws {
        let store = CleanupManagerStore()
        let a = file("/R/folder/sub/a", 1, .userCache)
        let b = file("/R/folder/sub/b", 1, .userCache)
        store.load(result: ScanResult(items: [a, b, file("/R/z", 1, .userCache)]))
        let rows = store.items(forCategoryID: "userCache")
        let row = try #require(rows.first { $0.title == "folder" })

        #expect(store.selectionState(forRowID: row.id, selectionRevision: 1) { _ in false } == .none)
        #expect(store.selectionState(forRowID: row.id, selectionRevision: 2) { $0 == a } == .some)
        #expect(store.selectionState(forRowID: row.id, selectionRevision: 3) { _ in true } == .all)
        #expect(store.someFilesSelected(forRowID: row.id, selectionRevision: 4) { $0 == b })
        #expect(!store.someFilesSelected(forRowID: row.id, selectionRevision: 5) { _ in true })
    }

    @Test("A row with nothing behind it reports none")
    func unknownRowIsNone() {
        let store = CleanupManagerStore()
        store.load(result: ScanResult(items: [file("/R/z", 1, .userCache)]))
        _ = store.items(forCategoryID: "userCache")

        #expect(store.selectionState(forRowID: "/no/such/row", selectionRevision: 1) { _ in true } == .none)
    }
}
