// SmartScanSimilarImagesReview.swift
// Similar-photos Review for Smart Scan — the shared three-pane manager over near-duplicate image groups. One category per group lists the extra shots; the best shot (the kept original) is named but never listed, so it can't be deleted.

import SwiftUI

/// Holds the id→file and url→size lookups the selection callbacks need, built on
/// the same background pass as the section model so nothing O(all-files) runs on
/// the main thread; read on the main actor once that build finishes.
private final class SimilarReviewLookups: @unchecked Sendable {
    var filesByID: [String: ScannedFile] = [:]
    var sizeByURL: [URL: Int64] = [:]
}

/// Similar Images Review, rendered through the shared `SmartScanReviewManager`.
/// Each group is one category whose items are the extra near-duplicate shots;
/// the best shot is named in the category title but never listed, so it can
/// never be selected for deletion. These are the user's own photos, so nothing
/// is pre-checked — the card's selection fills only from explicit choices here.
struct SmartScanSimilarImagesReview: View {
    var viewModel: SmartScanViewModel
    let groups: [SimilarImageGroup]
    let onBack: () -> Void

    @State private var lookups = SimilarReviewLookups()

    var body: some View {
        let lookups = self.lookups
        let groups = self.groups
        SmartScanReviewManager(
            title: String(
                localized: "Similar Photos",
                comment: "Title on the Smart Scan similar-images Review screen."
            ),
            buildSections: {
                // Only the extra shots are deletable, so only they enter the
                // lookups — the kept best shot can never be toggled.
                let copies = groups.flatMap { $0.redundantCopies }
                lookups.filesByID = Dictionary(copies.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
                lookups.sizeByURL = Dictionary(copies.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
                return Self.buildSections(groups: groups)
            },
            isSelected: { id in
                guard let file = lookups.filesByID[id] else { return false }
                return viewModel.isSimilarImageSelected(file)
            },
            onToggle: { id in
                guard let file = lookups.filesByID[id] else { return }
                viewModel.toggleSimilarImage(file)
            },
            onSetCategory: { category, selected in
                let urls = category.items.map { URL(fileURLWithPath: $0.id) }
                viewModel.setSimilarImages(urls, selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.similarImages",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                let selection = viewModel.similarImageSelection
                let bytes = selection.reduce(Int64(0)) { $0 + (lookups.sizeByURL[$1] ?? 0) }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    nonisolated private static func buildSections(groups: [SimilarImageGroup]) -> [ManagerSection] {
        let categories = groups.compactMap { category(for: $0) }
        guard !categories.isEmpty else { return [] }
        return [ManagerSection(
            id: "similarImages",
            title: String(localized: "Similar Photos", comment: "Similar-images Review left-pane section title."),
            categories: categories,
            description: String(
                localized: "These are your photos — nothing is removed unless you check it.",
                comment: "Header reminding that similar photos are opt-in."
            )
        )]
    }

    /// One category per group: its items are the extra shots, and its title
    /// names the best shot that will be kept.
    nonisolated private static func category(for group: SimilarImageGroup) -> ManagerCategory? {
        let copies = group.redundantCopies
        guard !copies.isEmpty else { return nil }
        let items = copies.map { file -> ManagerItem in
            ManagerItem(
                id: file.url.path,
                title: file.url.lastPathComponent,
                subtitle: file.url.deletingLastPathComponent().path,
                size: file.size,
                sizeText: ManagerByteText.string(file.size),
                systemImage: "photo.fill",
                tint: .blue,
                usesFileIcon: true
            )
        }
        let total = group.reclaimableBytes
        let keptName = group.original.url.lastPathComponent
        return ManagerCategory(
            id: group.original.url.path,
            title: String(
                localized: "Near-copies of “\(keptName)”",
                comment: "Similar-images Review category title; the named file is the best shot that is kept."
            ),
            systemImage: "photo.on.rectangle.angled",
            tint: .orange,
            items: items,
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
    }
}
