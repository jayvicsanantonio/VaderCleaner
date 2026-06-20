// SmartScanMyClutterReview.swift
// My Clutter "Manager" for Smart Scan — the shared three-pane manager over large/old files, grouped by kind, with per-file selection. Selection defaults to empty (destructive deletes are opt-in). The model is built off the main thread so large clutter scans open without blocking.

import SwiftUI

/// Holds the id→file and url→size lookups the selection callbacks need. Built
/// on the same background task as the section model so nothing O(N) runs on the
/// main thread; read on the main actor once that build has finished.
private final class ClutterReviewLookups: @unchecked Sendable {
    var filesByID: [String: ScannedFile] = [:]
    var sizeByURL: [URL: Int64] = [:]
}

/// My Clutter Review, rendered through the shared `SmartScanReviewManager`.
/// Files are grouped into Large vs. Old; selection bridges to the view model's
/// per-file API. Nothing is selected by default — parity with
/// `LargeOldFilesViewModel`, where destructive deletes are opt-in.
struct SmartScanMyClutterReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onBack: () -> Void

    @State private var lookups = ClutterReviewLookups()

    /// Pre-sorted by `SmartScanViewModel` when results land.
    private var sortedFiles: [ScannedFile] {
        viewModel.sortedLargeOldFiles
    }

    var body: some View {
        let lookups = self.lookups
        let allFiles = sortedFiles
        SmartScanReviewManager(
            title: String(
                localized: "Clutter Manager",
                comment: "Title on the Smart Scan My Clutter Review screen."
            ),
            buildSections: {
                // Build the selection lookups on the same off-main pass as the
                // section model, so the main thread never does O(all-files) work.
                lookups.filesByID = Dictionary(allFiles.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
                lookups.sizeByURL = Dictionary(allFiles.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
                return Self.buildSections(files: allFiles)
            },
            isSelected: { id in
                guard let file = lookups.filesByID[id] else { return false }
                return viewModel.isLargeFileSelected(file)
            },
            onToggle: { id in
                guard let file = lookups.filesByID[id] else { return }
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
                let bytes = selection.reduce(Int64(0)) { $0 + (lookups.sizeByURL[$1] ?? 0) }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    nonisolated private static func buildSections(files: [ScannedFile]) -> [ManagerSection] {
        let categories = [
            category(files, scanCategory: .largeFile,
                     title: String(localized: "Large Files", comment: "Clutter Manager category for large files."),
                     systemImage: "doc.fill"),
            category(files, scanCategory: .oldFile,
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

    nonisolated private static func category(
        _ files: [ScannedFile],
        scanCategory: ScanCategory,
        title: String,
        systemImage: String
    ) -> ManagerCategory? {
        // `files` arrives pre-sorted by size, so the filtered slice stays sorted.
        let matching = files.filter { $0.category == scanCategory }
        guard !matching.isEmpty else { return nil }
        let items = matching.map { file -> ManagerItem in
            let isDir = file.url.pathExtension.isEmpty
            return ManagerItem(
                id: file.url.path,
                title: file.url.lastPathComponent,
                subtitle: file.url.deletingLastPathComponent().path,
                size: file.size,
                sizeText: ManagerByteText.string(file.size),
                systemImage: isDir ? "folder.fill" : "doc.fill",
                tint: isDir ? .blue : .secondary
            )
        }
        let total = matching.reduce(Int64(0)) { $0 + $1.size }
        return ManagerCategory(
            id: scanCategory.rawValue,
            title: title,
            systemImage: systemImage,
            tint: .orange,
            items: items,
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
    }
}
