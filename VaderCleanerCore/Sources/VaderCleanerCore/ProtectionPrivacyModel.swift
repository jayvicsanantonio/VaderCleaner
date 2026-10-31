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
public final class ProtectionPrivacyModel {

    public enum Phase: Equatable { case idle, scanning, ready, removing }

    /// Identity of one `(browser, category)` cell.
    struct Key: Hashable, Sendable {
        let browser: Browser
        let category: ProtectionPrivacyCategory
    }

    typealias Detect = @Sendable () async -> [Browser]
    typealias CountProvider = @Sendable (Browser, ProtectionPrivacyCategory) async -> Int
    typealias ItemsProvider = @Sendable (Browser, ProtectionPrivacyCategory) async -> [PrivacyItem]
    typealias AvailabilityProvider = @Sendable (Browser, ProtectionPrivacyCategory) async -> PrivacyDataAvailability
    typealias Remove = @Sendable ([PrivacyRemovalRequest]) async throws -> Void

    public private(set) var phase: Phase = .idle
    public private(set) var browsers: [Browser] = []
    /// Set when a removal is refused because a browser is open; the manager
    /// surfaces it and clears it on the next action.
    public private(set) var blockedByRunningBrowser: Browser?
    /// Why the last removal didn't remove everything, until dismissed.
    public private(set) var removalFailureMessage: String?

    /// Called once a removal has finished and the numbers here are current, so
    /// anything showing the same data can catch up.
    @ObservationIgnored public var onDataChanged: (() -> Void)?

    private var counts: [Key: Int] = [:]
    private var availabilities: [Key: PrivacyDataAvailability] = [:]
    private var itemsByKey: [Key: [PrivacyItem]] = [:]
    /// Whole-category selection (non-expandable removable categories).
    private var selectedCategories: Set<Key> = []
    /// Per-item selection (expandable categories): selected `PrivacyItem.id`s.
    private var selectedItems: [Key: Set<String>] = [:]

    @ObservationIgnored private let detect: Detect
    @ObservationIgnored private let countProvider: CountProvider
    @ObservationIgnored private let itemsProvider: ItemsProvider
    @ObservationIgnored private let availabilityProvider: AvailabilityProvider
    @ObservationIgnored private let removeAction: Remove

    /// Identifies the operation that currently owns the published state.
    ///
    /// `phase` cannot do this job: `scan()` and `remove()` both write it, so a
    /// removal landing mid-scan erased the `.scanning` marker and let the
    /// finishing scan republish its *pre-removal* snapshot — permanently
    /// restoring rows the user had just deleted, since nothing re-triggers a
    /// scan afterwards. Every publish is gated on still owning this token.
    @ObservationIgnored private var operationGeneration = 0

    init(
        detect: @escaping Detect,
        count: @escaping CountProvider,
        items: @escaping ItemsProvider,
        availability: @escaping AvailabilityProvider = { _, _ in .available },
        remove: @escaping Remove
    ) {
        self.detect = detect
        self.countProvider = count
        self.itemsProvider = items
        self.availabilityProvider = availability
        self.removeAction = remove
    }

    // MARK: - Scan

    /// Detects browsers and scans every category's count + (for expandable
    /// categories) its items. Idempotent re-scan after a removal refreshes the
    /// numbers. No-op if already scanning, or while a removal runs, which scans
    /// when it finishes.
    public func scan() async {
        guard phase != .scanning, phase != .removing else { return }
        await runScan()
    }

    private func runScan() async {
        let generation = beginOperation()
        phase = .scanning
        let found = await detect()
        var newCounts: [Key: Int] = [:]
        var newItems: [Key: [PrivacyItem]] = [:]
        var newAvailabilities: [Key: PrivacyDataAvailability] = [:]
        for browser in found {
            for category in ProtectionPrivacyCategory.allCases {
                let key = Key(browser: browser, category: category)
                newCounts[key] = await countProvider(browser, category)
                newAvailabilities[key] = await availabilityProvider(browser, category)
                if category.isExpandable {
                    newItems[key] = await itemsProvider(browser, category)
                }
            }
        }
        // A scan superseded by a removal (or a newer scan) must not publish:
        // its numbers describe the world before that operation ran. It leaves
        // `phase` alone too — whoever superseded it owns that now.
        guard operationGeneration == generation else { return }
        browsers = found
        counts = newCounts
        itemsByKey = newItems
        availabilities = newAvailabilities
        dropSelectionsForDataThatIsGone()
        phase = .ready
    }

    /// A selection can only stand for something still listed, or the footer would
    /// count items nobody can see and Remove would act on them.
    private func dropSelectionsForDataThatIsGone() {
        selectedCategories = selectedCategories.filter { (counts[$0] ?? 0) > 0 }
        for (key, ids) in selectedItems {
            let listed = Set((itemsByKey[key] ?? []).map(\.id))
            selectedItems[key] = ids.intersection(listed)
        }
    }

    /// Claims ownership of the published state for a new operation, superseding
    /// any still in flight.
    private func beginOperation() -> Int {
        operationGeneration &+= 1
        return operationGeneration
    }

    // MARK: - Reads

    public func count(_ browser: Browser, _ category: ProtectionPrivacyCategory) -> Int {
        counts[Key(browser: browser, category: category)] ?? 0
    }

    public func items(_ browser: Browser, _ category: ProtectionPrivacyCategory) -> [PrivacyItem] {
        itemsByKey[Key(browser: browser, category: category)] ?? []
    }

    /// What the user could actually remove for this browser. Excludes the
    /// informational categories, which can dwarf it (history alone runs to six
    /// figures) without any of it being on offer.
    public func removableCount(_ browser: Browser) -> Int {
        ProtectionPrivacyCategory.allCases
            .filter { $0.kind == .removable }
            .reduce(0) { $0 + count(browser, $1) }
    }

    public func availability(_ browser: Browser, _ category: ProtectionPrivacyCategory) -> PrivacyDataAvailability {
        availabilities[Key(browser: browser, category: category)] ?? .available
    }

    // MARK: - Search

    /// The rows search leaves on screen: all of them when it's empty or names the
    /// category itself, otherwise the ones whose label matches.
    public func visibleItems(_ browser: Browser, _ category: ProtectionPrivacyCategory, search: String) -> [PrivacyItem] {
        let all = items(browser, category)
        guard !search.isEmpty, !category.displayName.localizedCaseInsensitiveContains(search) else { return all }
        return all.filter { $0.label.localizedCaseInsensitiveContains(search) }
    }

    public func isCategoryVisible(_ browser: Browser, _ category: ProtectionPrivacyCategory, search: String) -> Bool {
        search.isEmpty
            || category.displayName.localizedCaseInsensitiveContains(search)
            || !visibleItems(browser, category, search: search).isEmpty
    }

    public func browserMatches(_ browser: Browser, search: String) -> Bool {
        ProtectionPrivacyCategory.allCases.contains { isCategoryVisible(browser, $0, search: search) }
    }

    // MARK: - Selection state

    public enum CheckState { case off, on, mixed }

    public func categoryState(_ browser: Browser, _ category: ProtectionPrivacyCategory) -> CheckState {
        let key = Key(browser: browser, category: category)
        if category.isExpandable {
            let selected = selectedItems[key]?.count ?? 0
            let total = itemsByKey[key]?.count ?? 0
            if selected == 0 { return .off }
            return selected >= total ? .on : .mixed
        }
        return selectedCategories.contains(key) ? .on : .off
    }

    public func isItemSelected(_ browser: Browser, _ category: ProtectionPrivacyCategory, _ itemID: String) -> Bool {
        selectedItems[Key(browser: browser, category: category)]?.contains(itemID) ?? false
    }

    /// Total selected units (per-item rows + whole-category selections), for the
    /// footer summary and Remove enablement.
    public var selectedCount: Int {
        selectedCategories.count + selectedItems.values.reduce(0) { $0 + $1.count }
    }

    public var hasSelection: Bool { selectedCount > 0 }

    public func hasSelection(in browser: Browser) -> Bool {
        selectedCategories.contains { $0.browser == browser }
            || selectedItems.contains { $0.key.browser == browser && !$0.value.isEmpty }
    }

    /// One line per browser naming what Remove will act on, since the selection
    /// can span browsers the user isn't looking at.
    public var removalSummaryLines: [String] {
        Browser.allCases.compactMap { browser in
            let parts = ProtectionPrivacyCategory.allCases.compactMap { category -> String? in
                let key = Key(browser: browser, category: category)
                if selectedCategories.contains(key) { return category.displayName }
                let chosen = selectedItems[key]?.count ?? 0
                guard chosen > 0 else { return nil }
                let total = itemsByKey[key]?.count ?? 0
                guard chosen < total else { return category.displayName }
                return String(
                    localized: "\(category.displayName) (\(chosen) of \(total))",
                    bundle: .module,
                    comment: "A partly selected privacy category in the removal confirmation."
                )
            }
            guard !parts.isEmpty else { return nil }
            return "\(browser.displayName): \(parts.joined(separator: ", "))"
        }
    }

    // MARK: - Selection mutation

    public func toggleCategory(_ browser: Browser, _ category: ProtectionPrivacyCategory) {
        guard category.kind == .removable else { return }
        let key = Key(browser: browser, category: category)
        if category.isExpandable {
            let all = Set((itemsByKey[key] ?? []).map(\.id))
            let current = selectedItems[key] ?? []
            selectedItems[key] = current.count >= all.count && !all.isEmpty ? [] : all
        } else {
            if selectedCategories.contains(key) { selectedCategories.remove(key) } else { selectedCategories.insert(key) }
        }
    }

    public func toggleItem(_ browser: Browser, _ category: ProtectionPrivacyCategory, _ itemID: String) {
        let key = Key(browser: browser, category: category)
        var set = selectedItems[key] ?? []
        if set.contains(itemID) { set.remove(itemID) } else { set.insert(itemID) }
        selectedItems[key] = set
    }

    /// Select/deselect what the current search leaves visible in one browser's
    /// right pane (the Select menu). An empty category has nothing to select.
    public func setAllSelected(_ value: Bool, browser: Browser, search: String = "") {
        for category in ProtectionPrivacyCategory.allCases
        where category.kind == .removable && isCategoryVisible(browser, category, search: search) {
            let key = Key(browser: browser, category: category)
            if category.isExpandable {
                let visible = Set(visibleItems(browser, category, search: search).map(\.id))
                var selected = selectedItems[key] ?? []
                if value { selected.formUnion(visible) } else { selected.subtract(visible) }
                selectedItems[key] = selected
            } else if value, count(browser, category) > 0 {
                selectedCategories.insert(key)
            } else if !value {
                selectedCategories.remove(key)
            }
        }
    }

    public func deselectAll() {
        selectedCategories = []
        selectedItems = [:]
    }

    /// Dismisses the running-browser block after the user has acknowledged it.
    public func acknowledgeBlock() {
        blockedByRunningBrowser = nil
    }

    public func dismissRemovalFailure() {
        removalFailureMessage = nil
    }

    // MARK: - Remove

    /// Removes the current selection. On success, clears the selection and
    /// re-scans. If a target browser is open, records `blockedByRunningBrowser`
    /// and removes nothing. If something couldn't be removed, records why and
    /// re-scans, leaving what's still there ticked for a retry.
    public func remove() async {
        await perform(removalRequests())
    }

    /// Removes everything the manager is allowed to remove for one browser, for
    /// the dashboard tile. Returns whether it's all gone. Informational categories
    /// are never touched here either: the tile's promise and the manager's have
    /// to be the same one.
    public func removeAllData(for browser: Browser) async -> Bool {
        let requests = ProtectionPrivacyCategory.allCases
            .filter { $0.kind == .removable && count(browser, $0) > 0 }
            .map { PrivacyRemovalRequest(browser: browser, category: $0, scope: .wholeCategory) }
        return await perform(requests)
    }

    @discardableResult
    private func perform(_ requests: [PrivacyRemovalRequest]) async -> Bool {
        guard !requests.isEmpty else { return true }
        // Claimed before the await: a scan already in flight is now stale, and
        // must not land its pre-removal counts on top of this removal.
        let generation = beginOperation()
        blockedByRunningBrowser = nil
        removalFailureMessage = nil
        phase = .removing
        do {
            try await removeAction(requests)
            guard operationGeneration == generation else { return true }
            clearSelection(for: requests)
            await runScan()
            onDataChanged?()
            return true
        } catch let PrivacyRemovalError.browserRunning(browser) {
            guard operationGeneration == generation else { return false }
            blockedByRunningBrowser = browser
            phase = .ready
            return false
        } catch {
            guard operationGeneration == generation else { return false }
            removalFailureMessage = error.localizedDescription
            await runScan()
            onDataChanged?()
            return false
        }
    }

    private func clearSelection(for requests: [PrivacyRemovalRequest]) {
        for request in requests {
            let key = Key(browser: request.browser, category: request.category)
            selectedCategories.remove(key)
            selectedItems[key] = nil
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
                    scope: .items(hostKeys: chosen.compactMap(\.hostKey))
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
    public static func live() -> ProtectionPrivacyModel {
        let detector = DefaultBrowserDetector()
        let pathProvider = DefaultBrowserDataPathProvider()
        let inspector = BrowserPrivacyInspector(pathProvider: pathProvider)
        let remover = BrowserPrivacyRemover(pathProvider: pathProvider)
        return ProtectionPrivacyModel(
            detect: { detector.installedBrowsers() },
            count: { await inspector.count(for: $1, browser: $0) },
            items: { await inspector.items(for: $1, browser: $0) },
            availability: { await inspector.availability(for: $1, browser: $0) },
            remove: { try await remover.remove($0) }
        )
    }
}
