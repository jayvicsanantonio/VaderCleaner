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

    /// Left-pane groupings, mirroring the reference's "System Junk / Mail
    /// Attachments / Trash" split. Only groups (and categories) with scanned
    /// items are shown.
    private static let groups: [(id: String, title: String, categories: [ScanCategory])] = [
        ("systemJunk", String(localized: "System Junk", comment: "Cleanup Manager section grouping the general system/user caches and logs."),
         [.systemCache, .userCache, .systemLogs, .userLogs, .languageFiles, .iosBackups]),
        ("mailAttachments", String(localized: "Mail Attachments", comment: "Cleanup Manager section for mail attachment files."),
         [.mailAttachments]),
        ("trash", String(localized: "Trash", comment: "Cleanup Manager section for the trash bins."),
         [.trash]),
    ]

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
                return Self.buildSections(itemsByCategory: itemsByCategory, sizeByCategory: sizeByCategory)
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

    /// Builds the section model off the main actor. Pure and `nonisolated`, over
    /// `Sendable` inputs, so it can run on a background task. Each category's
    /// files are pre-sorted by size (the manager's default order) and carry a
    /// precomputed size string, so neither the build's caller nor scrolling
    /// touches the main thread for sorting or formatting.
    nonisolated private static func buildSections(
        itemsByCategory: [ScanCategory: [ScannedFile]],
        sizeByCategory: [ScanCategory: Int64]
    ) -> [ManagerSection] {
        groups.compactMap { group in
            let categories = group.categories.compactMap { category -> ManagerCategory? in
                guard let files = itemsByCategory[category], !files.isEmpty else { return nil }
                let sortedFiles = files.sorted { $0.size > $1.size }
                let items = sortedFiles.map { file in
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
                let total = sizeByCategory[category] ?? files.reduce(0) { $0 + $1.size }
                return ManagerCategory(
                    id: category.rawValue,
                    title: category.displayName,
                    systemImage: icon(for: category),
                    tint: .green,
                    items: items,
                    totalSize: total,
                    totalSizeText: ManagerByteText.string(total)
                )
            }
            guard !categories.isEmpty else { return nil }
            return ManagerSection(id: group.id, title: group.title, categories: categories)
        }
    }

    /// SF Symbol for each junk category's middle-pane row.
    nonisolated private static func icon(for category: ScanCategory) -> String {
        switch category {
        case .systemCache: return "internaldrive"
        case .userCache: return "clock.arrow.circlepath"
        case .systemLogs: return "doc.text.magnifyingglass"
        case .userLogs: return "doc.text"
        case .languageFiles: return "globe"
        case .mailAttachments: return "paperclip"
        case .iosBackups: return "iphone"
        case .trash: return "trash"
        case .largeFile, .oldFile: return "doc"
        }
    }
}
