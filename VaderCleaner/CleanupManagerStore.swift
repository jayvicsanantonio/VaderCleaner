// CleanupManagerStore.swift
// Persistent, prebuilt cache behind the Cleanup Manager so opening Review paints instantly: it serves the cheap section/category shell, builds and caches each category's folder tree off the main thread, prebuilds everything in the background as soon as a scan finishes, and holds the path→file / row→paths lookups the selection callbacks need.

import Foundation

/// Caches the Cleanup Manager's model across opens and warms it in the
/// background after a scan, so the panes and right-pane rows appear without the
/// per-open rebuild that used to gate them behind a spinner.
///
/// Thread-safe via a lock (`@unchecked Sendable`): the manager's `@Sendable`
/// build closures call in from background tasks while the selection callbacks
/// read from the main actor. The heavy tree-building runs through
/// `CleanupManagerModel`'s `nonisolated` builders.
final class CleanupManagerStore: @unchecked Sendable {

    private let lock = NSLock()

    // Inputs, copied from the latest scan result.
    private var itemsByCategory: [ScanCategory: [ScannedFile]] = [:]
    private var sizeByCategory: [ScanCategory: Int64] = [:]

    // Caches.
    private var shellCache: [ManagerSection]?
    private var itemsCache: [String: [ManagerItem]] = [:]
    /// Leaf file path → file, for toggling selection. Built off-main.
    private var filesByPath: [String: ScannedFile] = [:]
    /// Row id (folder or file) → the leaf file paths it covers, populated as
    /// each category's tree is built.
    private var pathsByRowID: [String: [String]] = [:]

    /// Bumped on every `load` so a stale background prebuild stops early.
    private var token = 0

    /// Point the store at a new scan result: reset the caches and warm them
    /// (path index, shell, every category tree) on a background task so the
    /// model is ready by the time the user opens Review.
    func load(result: ScanResult) {
        lock.lock()
        itemsByCategory = result.itemsByCategory
        sizeByCategory = result.sizeByCategory
        shellCache = nil
        itemsCache = [:]
        filesByPath = [:]
        pathsByRowID = [:]
        token += 1
        let myToken = token
        let allItems = result.items
        let categories = itemsByCategory.keys.map { $0 }
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // The path index first, so selection works as soon as rows appear.
            let map = Dictionary(allItems.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
            self.lock.lock()
            if self.token == myToken { self.filesByPath = map }
            self.lock.unlock()

            guard self.isCurrent(myToken) else { return }
            _ = self.sections()
            for category in categories {
                guard self.isCurrent(myToken) else { return }
                _ = self.items(forCategoryID: category.rawValue)
            }
        }
    }

    private func isCurrent(_ myToken: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == myToken
    }

    /// The section/category shell (cheap; built once and cached).
    func sections() -> [ManagerSection] {
        lock.lock()
        if let shellCache {
            lock.unlock()
            return shellCache
        }
        let ibc = itemsByCategory
        let sbc = sizeByCategory
        lock.unlock()

        let built = CleanupManagerModel.buildShell(
            itemsByCategory: ibc,
            sizeByCategory: sbc,
            includeEmptySections: true
        )
        lock.lock()
        shellCache = built
        lock.unlock()
        return built
    }

    /// The folder tree for one category (built once and cached). Indexes the
    /// rows' selection paths so the selection callbacks can resolve them.
    func items(forCategoryID id: String) -> [ManagerItem] {
        lock.lock()
        if let cached = itemsCache[id] {
            lock.unlock()
            return cached
        }
        let files = ScanCategory(rawValue: id).flatMap { itemsByCategory[$0] } ?? []
        lock.unlock()

        let tree = CleanupManagerModel.buildHierarchy(files)

        lock.lock()
        itemsCache[id] = tree
        indexRows(tree)
        lock.unlock()
        return tree
    }

    /// Records each row's covered leaf paths. Call under `lock`.
    private func indexRows(_ rows: [ManagerItem]) {
        for row in rows {
            pathsByRowID[row.id] = row.selectionPaths.isEmpty ? [row.id] : row.selectionPaths
            indexRows(row.children)
        }
    }

    // MARK: - Selection lookups (read from the main actor)

    /// The leaf paths a row covers (a folder's subtree, or a single file).
    func selectionPaths(forRowID id: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return pathsByRowID[id] ?? [id]
    }

    /// The scanned file at `path`, once the background index has it.
    func file(forPath path: String) -> ScannedFile? {
        lock.lock(); defer { lock.unlock() }
        return filesByPath[path]
    }
}
