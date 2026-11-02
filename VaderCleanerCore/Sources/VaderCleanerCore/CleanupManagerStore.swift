// CleanupManagerStore.swift
// Cache behind the Cleanup Manager so opening Review paints instantly: it serves the cheap section/category shell, warms the path index a scan finishes with, builds and caches each category's folder tree off the main thread on first open, and holds the path→file / row→paths lookups the selection callbacks need.

import Foundation

/// How much of what a manager row covers is selected, for its checkbox.
public enum ManagerRowSelection: Sendable {
    case none
    case some
    case all
}

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
public final class CleanupManagerStore: @unchecked Sendable {

    private let lock = NSLock()

    // Inputs, copied from the latest scan result.
    private var itemsByCategory: [ScanCategory: [ScannedFile]] = [:]
    private var sizeByCategory: [ScanCategory: Int64] = [:]

    // Caches.
    private var shellCache: [ManagerSection]?
    private var itemsCache: [String: [ManagerItem]] = [:]
    /// Leaf file path → file, for toggling selection. Built off-main.
    private var filesByPath: [String: ScannedFile] = [:]
    /// Whether `filesByPath` covers the current inputs.
    private var hasPathIndex = false
    /// Row id → the leaf file paths stored on that row, populated as each
    /// category's tree is built. Expandable folders are normally absent here;
    /// they resolve through `childRowIDsByRowID` instead, so a path is stored once
    /// (in its childless node) rather than once per ancestor.
    private var pathsByRowID: [String: [String]] = [:]
    /// Expandable-folder row id → its child row ids, so a folder's covered
    /// paths are the union of its children (resolved on demand).
    private var childRowIDsByRowID: [String: [String]] = [:]
    /// Memoized `allFilesSelected` answers, valid only for
    /// `cachedSelectionRevision`.
    private var rowSelectionCache: [String: ManagerRowSelection] = [:]
    /// The selection revision `rowSelectionCache` was built against; `nil`
    /// before the first query.
    private var cachedSelectionRevision: Int?
    /// The idle project artifacts for Web Development Junk, computed off-main as
    /// a byproduct of building that category's rows and read O(1) by the Select
    /// menu. `nil` until the category's rows are built — the menu simply omits
    /// the idle-projects pick until then, never blocking the main thread to
    /// compute it (the separation walks the whole category, a third of a million
    /// files under `~/.npm`).
    private var webDevIdleProjectFilesCache: [ScannedFile]?

    /// Bumped on every `load` so a stale background prebuild stops early.
    private var token = 0

    /// The big containers a `load`/`unload` swaps out, bundled so the caller
    /// can carry them into a background task: on a large scan they hold
    /// millions of entries, and deallocating them on the main thread stalls
    /// whatever UI update triggered the swap.
    private struct SupersededContent: Sendable {
        let itemsByCategory: [ScanCategory: [ScannedFile]]
        let itemsCache: [String: [ManagerItem]]
        let filesByPath: [String: ScannedFile]
        let pathsByRowID: [String: [String]]
        let childRowIDsByRowID: [String: [String]]
    }

    /// Swap in new inputs and empty caches, bump the token so in-flight
    /// background warms stop, and return the superseded containers for the
    /// caller to release off the main thread. Call under `lock`.
    private func replaceContent(
        itemsByCategory newItems: [ScanCategory: [ScannedFile]],
        sizeByCategory newSizes: [ScanCategory: Int64]
    ) -> SupersededContent {
        let superseded = SupersededContent(
            itemsByCategory: itemsByCategory,
            itemsCache: itemsCache,
            filesByPath: filesByPath,
            pathsByRowID: pathsByRowID,
            childRowIDsByRowID: childRowIDsByRowID
        )
        itemsByCategory = newItems
        sizeByCategory = newSizes
        shellCache = nil
        itemsCache = [:]
        filesByPath = [:]
        hasPathIndex = false
        pathsByRowID = [:]
        childRowIDsByRowID = [:]
        rowSelectionCache = [:]
        cachedSelectionRevision = nil
        webDevIdleProjectFilesCache = nil
        token += 1
        return superseded
    }

    /// Point the store at a new scan result: reset the caches and warm the
    /// path index and section shell on a background task, so selection works
    /// and the panes paint the moment Review opens. Category folder trees are
    /// left to build lazily on first open.
    func load(result: ScanResult) {
        lock.lock()
        let superseded = replaceContent(
            itemsByCategory: result.itemsByCategory,
            sizeByCategory: result.sizeByCategory
        )
        let myToken = token
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            // The previous scan's containers die here, on this background
            // task, rather than on the (main) thread that called `load`.
            withExtendedLifetime(superseded) {}
            guard let self else { return }
            // The path index first, so selection works as soon as rows appear.
            self.ensurePathIndex()

            // Warm the cheap shell so the panes paint instantly on open. Each
            // category's folder tree is built lazily on first open (see
            // `items(forCategoryID:)`) rather than prebuilt here — holding a
            // full tree per category, opened or not, dominated the retained
            // memory of a large scan.
            guard self.isCurrent(myToken) else { return }
            _ = self.sections()
        }
    }

    /// Drop everything the store serves — inputs, caches, and the path
    /// index — releasing the superseded containers on a background task so a
    /// large scan's index never deallocates on the main thread. The token
    /// bump makes any in-flight background warm from an earlier `load` land
    /// as a no-op instead of repopulating the store.
    func unload() {
        lock.lock()
        let superseded = replaceContent(itemsByCategory: [:], sizeByCategory: [:])
        lock.unlock()

        Task.detached(priority: .utility) {
            withExtendedLifetime(superseded) {}
        }
    }

    /// Builds the path→file index unless it already exists. Runs off-main: the
    /// warm calls it, and so does each category's first build, which means rows
    /// can never reach the screen before the index they resolve through. A row
    /// that outran a low-priority warm swallowed its checkbox click and showed
    /// unchecked. A warm and a build may both do the work once; the second result
    /// is simply dropped.
    private func ensurePathIndex() {
        lock.lock()
        guard !hasPathIndex else {
            lock.unlock()
            return
        }
        let myToken = token
        let inputs = itemsByCategory
        lock.unlock()

        let map = Dictionary(
            inputs.values.joined().map { ($0.url.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        lock.lock()
        if token == myToken, !hasPathIndex {
            filesByPath = map
            hasPathIndex = true
            // Anything answered before this point saw no files at all.
            rowSelectionCache.removeAll()
            cachedSelectionRevision = nil
        }
        lock.unlock()
    }

    private func isCurrent(_ myToken: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == myToken
    }

    /// The section/category shell (cheap; built once and cached).
    public func sections() -> [ManagerSection] {
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
        // A `load` or `unload` landed during the build, so this describes content
        // the store no longer serves.
        if token == myToken { shellCache = built }
        lock.unlock()
        return built
    }

    /// The rows for one category (built once and cached). Indexes the
    /// rows' selection paths so the selection callbacks can resolve them.
    public func items(forCategoryID id: String) -> [ManagerItem] {
        ensurePathIndex()
        lock.lock()
        if let cached = itemsCache[id] {
            lock.unlock()
            return cached
        }
        let category = ScanCategory(rawValue: id)
        let files = category.flatMap { itemsByCategory[$0] } ?? []
        let myToken = token
        lock.unlock()

        // Web Development Junk needs the same expensive cache/project split for
        // both its rows and its idle-projects Select pick, so compute both in
        // one off-main pass here and cache the idle list for the O(1) menu read.
        let tree: [ManagerItem]
        var idleProjectFiles: [ScannedFile]?
        if category == .webDevJunk {
            let content = CleanupManagerModel.webDevContent(files)
            tree = content.items
            idleProjectFiles = content.idleProjectFiles
        } else {
            tree = category.map { CleanupManagerModel.buildItems(for: $0, files: files) } ?? []
        }

        lock.lock()
        defer { lock.unlock() }
        // A `load` or `unload` landed during the build: hand this tree to the
        // caller that asked for it, but keep it out of the caches, which now
        // belong to other content.
        guard token == myToken else { return tree }
        itemsCache[id] = tree
        if let idleProjectFiles { webDevIdleProjectFilesCache = idleProjectFiles }
        indexRows(tree)
        return tree
    }

    /// The idle project artifacts for Web Development Junk, or `nil` until that
    /// category's rows have been built (an O(1) read of the cache the build
    /// populates). The Select menu uses it to offer the idle-projects pick
    /// without ever rescanning the category on the main thread.
    public func webDevIdleProjectFiles() -> [ScannedFile]? {
        lock.lock(); defer { lock.unlock() }
        return webDevIdleProjectFilesCache
    }

    /// Records each row's selection index. A childless row stores the leaf paths
    /// it covers; an expandable folder stores its child row ids so its covered
    /// paths resolve as the union of its children — keeping a path out of every
    /// ancestor's storage. The one path an expandable folder keeps is a scanned
    /// file that is the folder itself, which belongs to no child. Call under `lock`.
    private func indexRows(_ rows: [ManagerItem]) {
        for row in rows {
            if row.children.isEmpty {
                pathsByRowID[row.id] = row.selectionPaths.isEmpty ? [row.id] : row.selectionPaths
            } else {
                childRowIDsByRowID[row.id] = row.children.map(\.id)
                if !row.selectionPaths.isEmpty { pathsByRowID[row.id] = row.selectionPaths }
            }
            indexRows(row.children)
        }
    }

    /// Resolves a row's covered leaf paths: its stored paths plus the union of its
    /// children, or the id itself for a row the index doesn't know. Call under
    /// `lock`.
    private func resolvePaths(forRowID id: String) -> [String] {
        let stored = pathsByRowID[id]
        let children = childRowIDsByRowID[id]
        if stored == nil && children == nil { return [id] }
        return (stored ?? []) + (children ?? []).flatMap { resolvePaths(forRowID: $0) }
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
    public func files(forRowID id: String) -> [ScannedFile] {
        lock.lock(); defer { lock.unlock() }
        return resolvePaths(forRowID: id).compactMap { filesByPath[$0] }
    }

    /// Whether a row covers at least one indexed file and every one of them
    /// satisfies `isSelected` — the folder-row checkbox's checked state. See
    /// `selectionState`, which answers it.
    public func allFilesSelected(
        forRowID id: String,
        selectionRevision: Int,
        isSelected: (ScannedFile) -> Bool
    ) -> Bool {
        selectionState(forRowID: id, selectionRevision: selectionRevision, isSelected: isSelected) == .all
    }

    /// Whether a row covers selected and unselected files both — the folder-row
    /// checkbox's mixed state. A folder drawn empty here would read as "nothing in
    /// this folder goes" while its selected files still would.
    public func someFilesSelected(
        forRowID id: String,
        selectionRevision: Int,
        isSelected: (ScannedFile) -> Bool
    ) -> Bool {
        selectionState(forRowID: id, selectionRevision: selectionRevision, isSelected: isSelected) == .some
    }

    /// How much of a row is selected, answered by walking the row's index in
    /// place and stopping as soon as it has seen both a selected and an unselected
    /// file, instead of materializing the subtree's whole file array (which a
    /// visible folder row over a huge subtree re-allocated on every table reload).
    /// A row that resolves to no files answers `.none`. `isSelected` runs under the
    /// store's lock and must not call back into the store.
    ///
    /// Answers are memoized per `selectionRevision` — the view model's counter
    /// over its selection set — and the whole cache is dropped the moment that
    /// counter moves. Without it, a uniformly-selected folder row has nothing to
    /// stop early on and rescans its entire subtree every time the table
    /// configures its cell: `~/.npm` covers a quarter of a million files, so
    /// scrolling it back into view cost ~140 ms of `Set<URL>` lookups, once per
    /// appearance. The manager's per-category fast path
    /// (`SmartScanReviewManager.uniformSelection`) skips this call entirely
    /// while a category is uniformly all- or none-selected, but a category with
    /// a mixed selection — the normal state of Web Development Junk, whose
    /// caches are pre-checked and whose project artifacts are not — falls
    /// through to here for every row.
    public func selectionState(
        forRowID id: String,
        selectionRevision: Int,
        isSelected: (ScannedFile) -> Bool
    ) -> ManagerRowSelection {
        lock.lock(); defer { lock.unlock() }
        if cachedSelectionRevision != selectionRevision {
            rowSelectionCache.removeAll(keepingCapacity: true)
            cachedSelectionRevision = selectionRevision
        } else if let cached = rowSelectionCache[id] {
            return cached
        }
        var foundSelected = false
        var foundUnselected = false
        visitResolvedFiles(forRowID: id) { file in
            if isSelected(file) { foundSelected = true } else { foundUnselected = true }
            return !(foundSelected && foundUnselected)
        }
        let answer: ManagerRowSelection = foundSelected ? (foundUnselected ? .some : .all) : .none
        rowSelectionCache[id] = answer
        return answer
    }

    /// Visits a row's indexed files until `visit` returns `false`, mirroring
    /// `resolvePaths`' index order without materializing its array. Paths with no
    /// indexed file are skipped. Returns whether the walk ran to the end. Call
    /// under `lock`.
    @discardableResult
    private func visitResolvedFiles(forRowID id: String, _ visit: (ScannedFile) -> Bool) -> Bool {
        let stored = pathsByRowID[id]
        let children = childRowIDsByRowID[id]
        for path in stored ?? (children == nil ? [id] : []) {
            guard let file = filesByPath[path] else { continue }
            if !visit(file) { return false }
        }
        for child in children ?? [] where !visitResolvedFiles(forRowID: child, visit) {
            return false
        }
        return true
    }
}
