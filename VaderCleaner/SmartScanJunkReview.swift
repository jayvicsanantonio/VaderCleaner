// SmartScanJunkReview.swift
// System Junk "Cleanup Manager" for Smart Scan — a three-pane (sections → categories → files) manager with per-file selection, search, sort, and a live selected-count footer. The file model is built off the main thread so huge junk scans open without blocking the UI.

import SwiftUI

/// System Junk Review, rendered through the shared `SmartScanReviewManager`.
/// The section/category/file hierarchy is built off the main actor; selection
/// callbacks bridge to the view model's per-file junk selection.
/// Holds the id→file and url→size lookups the selection callbacks need. Built
/// once on the same background task as the section model (so nothing O(N) runs
/// on the main thread) and read on the main actor afterward; the manager only
/// renders interactive rows once that build has finished, so there is no race.
private final class JunkReviewLookups: @unchecked Sendable {
    var filesByID: [String: ScannedFile] = [:]
    var sizeByURL: [URL: Int64] = [:]
}

struct SmartScanJunkReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onBack: () -> Void

    @State private var lookups = JunkReviewLookups()

    var body: some View {
        let lookups = self.lookups
        let items = result.junkResult.items
        let itemsByCategory = result.junkResult.itemsByCategory
        let sizeByCategory = result.junkResult.sizeByCategory
        SmartScanReviewManager(
            title: String(
                localized: "Cleanup Manager",
                comment: "Title on the Smart Scan System Junk Review screen."
            ),
            buildSections: {
                // Build the selection lookups in the same off-main pass as the
                // section model, so the main thread never does O(all-files) work.
                lookups.filesByID = Dictionary(items.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
                lookups.sizeByURL = Dictionary(items.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
                return CleanupManagerModel.build(
                    itemsByCategory: itemsByCategory,
                    sizeByCategory: sizeByCategory,
                    includeEmptySections: false,
                    hierarchical: false
                )
            },
            isSelected: { id in
                guard let file = lookups.filesByID[id] else { return false }
                return viewModel.isJunkFileSelected(file)
            },
            onToggle: { id in
                guard let file = lookups.filesByID[id] else { return }
                viewModel.toggleJunkFile(file)
            },
            onSetCategory: { category, selected in
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return }
                viewModel.setJunkCategory(scanCategory, selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.junk",
            selectionSummary: {
                let selection = viewModel.junkFileSelection
                let bytes = selection.reduce(Int64(0)) { $0 + (lookups.sizeByURL[$1] ?? 0) }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }
}
