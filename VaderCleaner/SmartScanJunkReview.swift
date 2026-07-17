// SmartScanJunkReview.swift
// System Junk "Cleanup Manager" for Smart Scan — a store-backed three-pane (sections → categories → folder tree) manager with per-folder selection, search, sort, and a live selected-count footer. Panes paint instantly from a cheap shell and each category's rows load lazily, so huge junk scans open without blocking the UI.

import SwiftUI

/// System Junk Review, rendered through the shared `SmartScanReviewManager` and
/// served by the same `CleanupManagerStore` the standalone Cleanup Manager uses:
/// the panes paint from a cheap section/category shell and each category's folder
/// tree is built (and cached) lazily off the main thread. Selection is batched
/// per folder through the view model's `junkFileSelection`, with the manager's
/// per-category badges and bulk-select menu reading the view model's O(1)
/// tallies.
struct SmartScanJunkReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let store: CleanupManagerStore
    let onBack: () -> Void

    var body: some View {
        let store = self.store
        let itemsByCategory = result.junkResult.itemsByCategory
        SmartScanReviewManager(
            title: String(
                localized: "Cleanup Manager",
                comment: "Title on the Smart Scan System Junk Review screen."
            ),
            // Cheap shell: sections + category sizes, no file trees (warmed in
            // the background when the scan landed on `.results`).
            buildSections: { store.sections() },
            isSelected: { id in
                // Checked when every file beneath the row is selected. The walk
                // runs in place under one store lock and short-circuits on the
                // first unselected file, never materializing the subtree's file
                // array. (The manager's per-category fast path answers the
                // common all/none states before this runs at all.)
                store.allFilesSelected(forRowID: id) { viewModel.junkFileSelection.contains($0.url) }
            },
            onToggle: { id in
                // Whole-folder toggle in one batched pass: gather the row's files
                // under a single lock, then flip them together so a folder over
                // tens of thousands of files fires one UI update, not one per file.
                viewModel.toggleJunkFiles(store.files(forRowID: id))
            },
            onSetCategory: { category, selected in
                // Operate on the whole scan category (by id), independent of
                // whether its rows are loaded yet — one batched selection pass.
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return }
                viewModel.setJunkFiles(itemsByCategory[scanCategory] ?? [], selected: selected)
            },
            categorySelectedBytes: { category in
                // O(1) read of the view model's incrementally-maintained
                // per-category total, instead of reducing over every file in the
                // category on every render.
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return nil }
                return viewModel.selectedJunkBytes(in: scanCategory)
            },
            categorySelectionTally: { category in
                // O(1) None/All/Some for the bulk-select menu: the view model's
                // incrementally-maintained per-category selected count against the
                // scan's file count for that category.
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return nil }
                let total = itemsByCategory[scanCategory]?.count ?? 0
                return (selected: viewModel.selectedJunkCount(in: scanCategory), total: total)
            },
            loadItems: { id in
                // Off-main: a cache hit (usually, thanks to the prebuild) returns
                // instantly; a miss builds that one category's tree without
                // blocking the UI.
                await Task.detached(priority: .userInitiated) { store.items(forCategoryID: id) }.value
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.junk",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                ManagerSelectionSummary(
                    count: viewModel.junkFileSelection.count,
                    bytes: viewModel.selectedJunkBytes
                )
            }
        )
    }
}
