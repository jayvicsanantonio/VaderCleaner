// SmartScanMyClutterReview.swift
// My Clutter "Manager" for Smart Scan — the shared three-pane manager over large/old files, grouped by kind, with per-file selection. Selection defaults to empty (destructive deletes are opt-in).

import SwiftUI

/// My Clutter Review, rendered through the shared `SmartScanReviewManager`.
/// Files are grouped into Large vs. Old in the middle pane; selection bridges
/// to the view model's per-file API. Nothing is selected by default — parity
/// with `LargeOldFilesViewModel`, where destructive deletes are opt-in.
struct SmartScanMyClutterReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onBack: () -> Void

    /// Pre-sorted by `SmartScanViewModel` when results land, so building the
    /// manager model here doesn't re-sort on every refresh.
    private var sortedFiles: [ScannedFile] {
        viewModel.sortedLargeOldFiles
    }

    private var filesByID: [String: ScannedFile] {
        Dictionary(sortedFiles.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Byte size keyed by file URL, so the footer's selected-bytes total is an
    /// O(selected) sum rather than an O(all-files) scan on every checkbox tap.
    private var sizeByURL: [URL: Int64] {
        Dictionary(sortedFiles.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
    }

    private var sections: [ManagerSection] {
        let categories = [
            category(.largeFile,
                     title: String(localized: "Large Files", comment: "Clutter Manager category for large files."),
                     systemImage: "doc.fill"),
            category(.oldFile,
                     title: String(localized: "Old Files", comment: "Clutter Manager category for old files."),
                     systemImage: "clock.fill"),
        ].compactMap { $0 }
        guard !categories.isEmpty else { return [] }
        return [ManagerSection(
            id: "myClutter",
            title: String(localized: "My Clutter", comment: "Clutter Manager left-pane section title."),
            categories: categories
        )]
    }

    var body: some View {
        let files = filesByID
        let sizes = sizeByURL
        SmartScanReviewManager(
            title: String(
                localized: "Clutter Manager",
                comment: "Title on the Smart Scan My Clutter Review screen."
            ),
            sections: sections,
            isSelected: { id in
                guard let file = files[id] else { return false }
                return viewModel.isLargeFileSelected(file)
            },
            onToggle: { id in
                guard let file = files[id] else { return }
                viewModel.toggleLargeFile(file)
            },
            onSetCategory: { category, selected in
                let urls = category.items.map { URL(fileURLWithPath: $0.id) }
                viewModel.setLargeFiles(urls, selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.myClutter",
            selectionSummary: {
                let selection = viewModel.largeFileSelection
                let bytes = selection.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    private func category(
        _ scanCategory: ScanCategory,
        title: String,
        systemImage: String
    ) -> ManagerCategory? {
        let files = sortedFiles.filter { $0.category == scanCategory }
        guard !files.isEmpty else { return nil }
        return ManagerCategory(
            id: scanCategory.rawValue,
            title: title,
            systemImage: systemImage,
            iconColor: .orange,
            items: files.map { file in
                ManagerItem(
                    id: file.url.path,
                    title: file.url.lastPathComponent,
                    subtitle: file.url.deletingLastPathComponent().path,
                    size: file.size,
                    systemImage: file.url.pathExtension.isEmpty ? "folder.fill" : "doc.fill",
                    iconColor: file.url.pathExtension.isEmpty ? .blue : .secondary
                )
            }
        )
    }
}
