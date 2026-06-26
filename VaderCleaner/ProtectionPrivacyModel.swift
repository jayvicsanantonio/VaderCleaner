// ProtectionPrivacyModel.swift
// Observable model behind the Protection Manager's Privacy pane — detects browsers, scans per-category counts and per-item rows, tracks category + per-item selection, and removes the selection (refusing while a target browser is running).

import Foundation
import Observation

/// Drives the Protection Manager's Privacy pane. Collaborators are injected as
/// closures (detector, count, items, remove) so the selection/removal logic is
/// unit-testable without touching real browser data. Production wiring lives in
/// `ProtectionPrivacyModel.live()`.
@MainActor
@Observable
final class ProtectionPrivacyModel {

    enum Phase: Equatable { case idle, scanning, ready, removing }

    /// Identity of one `(browser, category)` cell.
    struct Key: Hashable, Sendable {
        let browser: Browser
        let category: ProtectionPrivacyCategory
    }

    typealias Detect = @Sendable () async -> [Browser]
    typealias CountProvider = @Sendable (Browser, ProtectionPrivacyCategory) async -> Int
    typealias ItemsProvider = @Sendable (Browser, ProtectionPrivacyCategory) async -> [PrivacyItem]
    typealias Remove = @Sendable ([PrivacyRemovalRequest]) async throws -> Void

    private(set) var phase: Phase = .idle
    private(set) var browsers: [Browser] = []
    /// Set when a removal is refused because a browser is open; the manager
    /// surfaces it and clears it on the next action.
    private(set) var blockedByRunningBrowser: Browser?

    private var counts: [Key: Int] = [:]
    private var itemsByKey: [Key: [PrivacyItem]] = [:]
    /// Whole-category selection (non-expandable removable categories).
    private var selectedCategories: Set<Key> = []
    /// Per-item selection (expandable categories): selected `PrivacyItem.id`s.
    private var selectedItems: [Key: Set<String>] = [:]

    @ObservationIgnored private let detect: Detect
    @ObservationIgnored private let countProvider: CountProvider
    @ObservationIgnored private let itemsProvider: ItemsProvider
    @ObservationIgnored private let removeAction: Remove

    init(detect: @escaping Detect, count: @escaping CountProvider, items: @escaping ItemsProvider, remove: @escaping Remove) {
        self.detect = detect
        self.countProvider = count
        self.itemsProvider = items
        self.removeAction = remove
    }

    // MARK: - Scan

    /// Detects browsers and scans every category's count + (for expandable
    /// categories) its items. Idempotent re-scan after a removal refreshes the
    /// numbers. No-op if already scanning.
    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        let found = await detect()
        var newCounts: [Key: Int] = [:]
        var newItems: [Key: [PrivacyItem]] = [:]
        for browser in found {
            for category in ProtectionPrivacyCategory.allCases {
                let key = Key(browser: browser, category: category)
                newCounts[key] = await countProvider(browser, category)
                if category.isExpandable {
                    newItems[key] = await itemsProvider(browser, category)
                }
            }
        }
        browsers = found
        counts = newCounts
        itemsByKey = newItems
        phase = .ready
    }

    // MARK: - Reads

    func count(_ browser: Browser, _ category: ProtectionPrivacyCategory) -> Int {
        counts[Key(browser: browser, category: category)] ?? 0
    }

    func items(_ browser: Browser, _ category: ProtectionPrivacyCategory) -> [PrivacyItem] {
        itemsByKey[Key(browser: browser, category: category)] ?? []
    }

    func totalCount(_ browser: Browser) -> Int {
        ProtectionPrivacyCategory.allCases.reduce(0) { $0 + count(browser, $1) }
    }

    // MARK: - Selection state

    enum CheckState { case off, on, mixed }

    func categoryState(_ browser: Browser, _ category: ProtectionPrivacyCategory) -> CheckState {
        let key = Key(browser: browser, category: category)
        if category.isExpandable {
            let selected = selectedItems[key]?.count ?? 0
            let total = itemsByKey[key]?.count ?? 0
            if selected == 0 { return .off }
            return selected >= total ? .on : .mixed
        }
        return selectedCategories.contains(key) ? .on : .off
    }

    func isItemSelected(_ browser: Browser, _ category: ProtectionPrivacyCategory, _ itemID: String) -> Bool {
        selectedItems[Key(browser: browser, category: category)]?.contains(itemID) ?? false
    }

    /// Total selected units (per-item rows + whole-category selections), for the
    /// footer summary and Remove enablement.
    var selectedCount: Int {
        selectedCategories.count + selectedItems.values.reduce(0) { $0 + $1.count }
    }

    var hasSelection: Bool { selectedCount > 0 }

    // MARK: - Selection mutation

    func toggleCategory(_ browser: Browser, _ category: ProtectionPrivacyCategory) {
        guard category.kind == .removable else { return }
        let key = Key(browser: browser, category: category)
        if category.isExpandable {
            let all = Set((itemsByKey[key] ?? []).map(\.id))
            let current = selectedItems[key] ?? []
            selectedItems[key] = current.count >= all.count && !all.isEmpty ? [] : all
        } else {
            if selectedCategories.contains(key) { selectedCategories.remove(key) }
            else { selectedCategories.insert(key) }
        }
    }

    func toggleItem(_ browser: Browser, _ category: ProtectionPrivacyCategory, _ itemID: String) {
        let key = Key(browser: browser, category: category)
        var set = selectedItems[key] ?? []
        if set.contains(itemID) { set.remove(itemID) } else { set.insert(itemID) }
        selectedItems[key] = set
    }

    /// Select/deselect everything for one browser's right pane (the Select menu).
    func setAllSelected(_ value: Bool, browser: Browser) {
        for category in ProtectionPrivacyCategory.allCases where category.kind == .removable {
            let key = Key(browser: browser, category: category)
            if category.isExpandable {
                selectedItems[key] = value ? Set((itemsByKey[key] ?? []).map(\.id)) : []
            } else if value {
                selectedCategories.insert(key)
            } else {
                selectedCategories.remove(key)
            }
        }
    }

    func deselectAll() {
        selectedCategories = []
        selectedItems = [:]
    }

    /// Dismisses the running-browser block after the user has acknowledged it.
    func acknowledgeBlock() {
        blockedByRunningBrowser = nil
    }

    // MARK: - Remove

    /// Removes the current selection. On success, clears the selection and
    /// re-scans. If a target browser is open, records `blockedByRunningBrowser`
    /// and removes nothing.
    func remove() async {
        let requests = removalRequests()
        guard !requests.isEmpty else { return }
        blockedByRunningBrowser = nil
        phase = .removing
        do {
            try await removeAction(requests)
            deselectAll()
            await scan()
        } catch let PrivacyRemovalError.browserRunning(browser) {
            blockedByRunningBrowser = browser
            phase = .ready
        } catch {
            phase = .ready
        }
    }

    /// Builds the removal requests from the selection. A fully-selected
    /// expandable category collapses to a single whole-category delete.
    func removalRequests() -> [PrivacyRemovalRequest] {
        var requests: [PrivacyRemovalRequest] = []
        for key in selectedCategories {
            requests.append(PrivacyRemovalRequest(browser: key.browser, category: key.category, scope: .wholeCategory))
        }
        for (key, ids) in selectedItems where !ids.isEmpty {
            let all = itemsByKey[key] ?? []
            if ids.count >= all.count {
                requests.append(PrivacyRemovalRequest(browser: key.browser, category: key.category, scope: .wholeCategory))
            } else {
                let chosen = all.filter { ids.contains($0.id) }
                requests.append(PrivacyRemovalRequest(
                    browser: key.browser,
                    category: key.category,
                    scope: .items(hostKeys: chosen.compactMap(\.hostKey), rowIDs: chosen.flatMap(\.rowIDs))
                ))
            }
        }
        return requests
    }
}

// MARK: - Production wiring

extension ProtectionPrivacyModel {

    /// Wires the model to the real detector, inspector, and remover.
    @MainActor
    static func live() -> ProtectionPrivacyModel {
        let detector = DefaultBrowserDetector()
        let pathProvider = DefaultBrowserDataPathProvider()
        let inspector = BrowserPrivacyInspector(pathProvider: pathProvider)
        let remover = BrowserPrivacyRemover(pathProvider: pathProvider)
        return ProtectionPrivacyModel(
            detect: { detector.installedBrowsers() },
            count: { await inspector.count(for: $1, browser: $0) },
            items: { await inspector.items(for: $1, browser: $0) },
            remove: { try await remover.remove($0) }
        )
    }
}
