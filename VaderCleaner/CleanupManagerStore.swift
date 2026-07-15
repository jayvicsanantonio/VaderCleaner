// CleanupManagerStore.swift
// Cache behind the Cleanup Manager so opening Review paints instantly: it serves the cheap section/category shell, warms the path index a scan finishes with, builds and caches each category's folder tree off the main thread on first open, and holds the path→file / row→paths lookups the selection callbacks need.

import Foundation

/// Caches the Cleanup Manager's model across opens and warms it in the
/// background after a scan, so the panes appear without a per-open rebuild.
///
/// The shell (section/category panes) and the path index are warmed eagerly;
/// each category's folder tree is built lazily on first open. Prewarming every
/// category's tree up front held a full folder tree in memory even for the
/// many categories a user never opens — on a large scan that dominated the
/// app's retained footprint — so the trees now build on demand (the manager's
/// `loadItems` already builds off-main without blocking the UI).
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
    /// Childless row id → the leaf file paths it covers, populated as each
    /// category's tree is built. Expandable folders are absent here; they
    /// resolve through `childRowIDsByRowID` instead, so a path is stored once
    /// (in its childless node) rather than once per ancestor.
    private var pathsByRowID: [String: [String]] = [:]
    /// Expandable-folder row id → its child row ids, so a folder's covered
    /// paths are the union of its children (resolved on demand).
    private var childRowIDsByRowID: [String: [String]] = [:]

    /// Bumped on every `load` so a stale background prebuild stops early.
    private var token = 0

    /// Point the store at a new scan result: reset the caches and warm the
    /// path index and section shell on a background task, so selection works
    /// and the panes paint the moment Review opens. Category folder trees are
    /// left to build lazily on first open.
    func load(result: ScanResult) {
        // On a large scan the superseded containers hold millions of strings
        // and files; swap them out under the lock but let their final release
        // happen on the background task below — freeing them on the calling
        // (main) thread stalled the UI for hundreds of milliseconds.
        lock.lock()
        let superseded = (itemsByCategory, itemsCache, filesByPath, pathsByRowID, childRowIDsByRowID)
        itemsByCategory = result.itemsByCategory
        sizeByCategory = result.sizeByCategory
        shellCache = nil
        itemsCache = [:]
        filesByPath = [:]
        pathsByRowID = [:]
        childRowIDsByRowID = [:]
        token += 1
        let myToken = token
        let allItems = result.items
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            // The superseded containers ride into this task so they deallocate
            // here, off the main thread, once the capture goes away.
            _ = superseded
            guard let self else { return }
            // The path index first, so selection works as soon as rows appear.
            let map = Dictionary(allItems.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
            self.lock.lock()
            if self.token == myToken { self.filesByPath = map }
            self.lock.unlock()

            // Warm the cheap shell so the panes paint instantly on open. Each
            // category's folder tree is built lazily on first open (see
            // `items(forCategoryID:)`) rather than prebuilt here — holding a
            // full tree per category, opened or not, dominated the retained
            // memory of a large scan.
            guard self.isCurrent(myToken) else { return }
            _ = self.sections()
        }
    }

    /// Drop the previous scan's data entirely: the shell, the trees, and the
    /// lookups all return to their empty state, so a reset session doesn't
    /// keep a large scan's index alive. Like `load`, the superseded containers
    /// are released on a background task rather than the caller's thread.
    func unload() {
        lock.lock()
        let superseded = (itemsByCategory, itemsCache, filesByPath, pathsByRowID, childRowIDsByRowID)
        itemsByCategory = [:]
        sizeByCategory = [:]
        shellCache = nil
        itemsCache = [:]
        filesByPath = [:]
        pathsByRowID = [:]
        childRowIDsByRowID = [:]
        token += 1
        lock.unlock()

        Task.detached(priority: .utility) {
            _ = superseded
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
        let myToken = token
        lock.unlock()

        let built = CleanupManagerModel.buildShell(
            itemsByCategory: ibc,
            sizeByCategory: sbc,
            includeEmptySections: true
        )
        lock.lock()
        // Only cache if a `load`/`unload` hasn't superseded these inputs while
        // we built off the lock. Without this, a warm task that read the
        // previous scan's data before an `unload` could write its stale shell
        // back after the store was cleared.
        if token == myToken { shellCache = built }
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
        let myToken = token
        lock.unlock()

        let tree = CleanupManagerModel.buildHierarchy(files)

        lock.lock()
        // Same supersession guard as `sections()`: a tree built from data a
        // later `load`/`unload` has replaced must not repopulate the cache.
        if token == myToken {
            itemsCache[id] = tree
            indexRows(tree)
        }
        lock.unlock()
        return tree
    }

    /// Records each row's selection index. A childless row stores the leaf paths
    /// it covers; an expandable folder stores its child row ids so its covered
    /// paths resolve as the union of its children — keeping a path out of every
    /// ancestor's storage. Call under `lock`.
    private func indexRows(_ rows: [ManagerItem]) {
        for row in rows {
            if row.children.isEmpty {
                pathsByRowID[row.id] = row.selectionPaths.isEmpty ? [row.id] : row.selectionPaths
            } else {
                childRowIDsByRowID[row.id] = row.children.map(\.id)
            }
            indexRows(row.children)
        }
    }

    /// Resolves a row's covered leaf paths. A childless row returns its stored
    /// paths; an expandable folder unions its children. Call under `lock`.
    private func resolvePaths(forRowID id: String) -> [String] {
        if let paths = pathsByRowID[id] { return paths }
        if let children = childRowIDsByRowID[id] {
            return children.flatMap { resolvePaths(forRowID: $0) }
        }
        return [id]
    }

    // MARK: - Selection lookups (read from the main actor)

    /// The leaf paths a row covers (a folder's subtree, or a single file).
    func selectionPaths(forRowID id: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return resolvePaths(forRowID: id)
    }

    /// The scanned file at `path`, once the background index has it.
    func file(forPath path: String) -> ScannedFile? {
        lock.lock(); defer { lock.unlock() }
        return filesByPath[path]
    }

    /// The scanned files a row covers (a folder's whole subtree, or a single
    /// file), resolved under a single lock. A folder toggle needs every
    /// descendant file; resolving them one `file(forPath:)` call at a time
    /// re-acquired the lock per path, so a big folder paid tens of thousands of
    /// lock round-trips just to gather its files.
    func files(forRowID id: String) -> [ScannedFile] {
        lock.lock(); defer { lock.unlock() }
        return resolvePaths(forRowID: id).compactMap { filesByPath[$0] }
    }
}
