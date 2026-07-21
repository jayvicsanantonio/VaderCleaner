// SmartScanDownloadsReview.swift
// Old-downloads Review for Smart Scan — the shared three-pane manager over the Downloads-folder findings, opt-in per file with Finder icons and source-app subtitles.

import SwiftUI

/// Holds the id→item and url→size lookups the selection callbacks need, built on
/// the same background pass as the section model so nothing O(all-files) runs on
/// the main thread; read on the main actor once that build finishes.
private final class DownloadsReviewLookups: @unchecked Sendable {
    var itemsByID: [String: DownloadItem] = [:]
    var sizeByURL: [URL: Int64] = [:]
}

/// Downloads Review, rendered through the shared `SmartScanReviewManager`. Every
/// row is the user's own file, so nothing is pre-checked — the card's selection
/// fills only from explicit choices here.
struct SmartScanDownloadsReview: View {
    var viewModel: SmartScanViewModel
    let items: [DownloadItem]
    let onBack: () -> Void

    @State private var lookups = DownloadsReviewLookups()

    var body: some View {
        let lookups = self.lookups
        let items = self.items
        SmartScanReviewManager(
            title: String(
                localized: "Old Downloads",
                comment: "Title on the Smart Scan downloads Review screen."
            ),
            buildSections: {
                lookups.itemsByID = Dictionary(items.map { ($0.file.url.path, $0) }, uniquingKeysWith: { a, _ in a })
                lookups.sizeByURL = Dictionary(items.map { ($0.file.url, $0.file.size) }, uniquingKeysWith: { a, _ in a })
                return Self.buildSections(items: items)
            },
            isSelected: { id in
                guard let item = lookups.itemsByID[id] else { return false }
                return viewModel.isDownloadSelected(item)
            },
            onToggle: { id in
                guard let item = lookups.itemsByID[id] else { return }
                viewModel.toggleDownload(item)
            },
            onSetCategory: { category, selected in
                let urls = category.items.map { URL(fileURLWithPath: $0.id) }
                viewModel.setDownloads(urls, selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.downloads",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                let selection = viewModel.downloadSelection
                let bytes = selection.reduce(Int64(0)) { $0 + (lookups.sizeByURL[$1] ?? 0) }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    nonisolated private static func buildSections(items: [DownloadItem]) -> [ManagerSection] {
        guard let category = category(items: items) else { return [] }
        return [ManagerSection(
            id: "downloads",
            title: String(localized: "Downloads", comment: "Downloads Review left-pane section title."),
            categories: [category],
            description: String(
                localized: "These are your files — nothing is removed unless you check it.",
                comment: "Header reminding that downloads are opt-in."
            )
        )]
    }

    nonisolated private static func category(items: [DownloadItem]) -> ManagerCategory? {
        guard !items.isEmpty else { return nil }
        let sorted = items.sorted { $0.file.size > $1.file.size }
        let managerItems = sorted.map { item -> ManagerItem in
            ManagerItem(
                id: item.file.url.path,
                title: item.file.url.lastPathComponent,
                subtitle: subtitle(for: item),
                size: item.file.size,
                sizeText: ManagerByteText.string(item.file.size),
                systemImage: "arrow.down.doc.fill",
                tint: .blue,
                usesFileIcon: true
            )
        }
        let total = items.reduce(Int64(0)) { $0 + $1.file.size }
        return ManagerCategory(
            id: "downloads",
            title: String(localized: "Downloads", comment: "Downloads Review category title."),
            systemImage: "arrow.down.circle.fill",
            tint: .blue,
            items: managerItems,
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
    }

    /// "From Safari · ~/Downloads" when the source is known, else just the
    /// folder — the facts a person needs to recognise an old download.
    nonisolated private static func subtitle(for item: DownloadItem) -> String {
        let folder = item.file.url.deletingLastPathComponent().path
        guard let source = item.sourceApp else { return folder }
        return String.localizedStringWithFormat(
            String(
                localized: "From %@ · %@",
                comment: "Download row subtitle: source app, containing folder."
            ),
            source, folder
        )
    }
}
