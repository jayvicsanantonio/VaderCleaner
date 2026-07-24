// SmartScanSimilarImagesReview.swift
// Similar-photos Review for Smart Scan — the shared two-pane manager over near-duplicate image groups, each row a Quick Look thumbnail. One category per group leads with the kept best shot as a locked row (shown, but no checkbox, so it can't be deleted) above the deletable near-duplicate copies.

import SwiftUI

/// Holds the id→file and url→size lookups the selection callbacks need, built on
/// the same background pass as the section model so nothing O(all-files) runs on
/// the main thread; read on the main actor once that build finishes.
private final class SimilarReviewLookups: @unchecked Sendable {
    var filesByID: [String: ScannedFile] = [:]
    var sizeByURL: [URL: Int64] = [:]
}

/// Similar Images Review, rendered through the shared `SmartScanReviewManager`.
/// Each group is one category: the kept best shot leads as a locked, thumbnailed
/// row (never entered into the selection lookups, so it can't be toggled),
/// followed by the deletable near-duplicate copies. These are the user's own
/// photos, so nothing is pre-checked — the selection fills only from explicit
/// choices here.
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
                // The kept best shot is a locked row — never sweep it into a
                // Select All / Deselect All.
                let urls = SmartScanReviewManager.selectableItems(category.items)
                    .map { URL(fileURLWithPath: $0.id) }
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

    /// One category per group. The kept best shot leads as a locked, thumbnailed
    /// row — shown so the user can see what survives, but with no checkbox so it
    /// can never be deleted — followed by the deletable near-duplicate copies,
    /// each with its own thumbnail.
    nonisolated private static func category(for group: SimilarImageGroup) -> ManagerCategory? {
        let copies = group.redundantCopies
        guard !copies.isEmpty else { return nil }
        let original = group.original
        let keptItem = ManagerItem(
            id: original.url.path,
            title: original.url.lastPathComponent,
            subtitle: original.url.deletingLastPathComponent().path,
            size: original.size,
            sizeText: ManagerByteText.string(original.size),
            systemImage: "photo.fill",
            tint: .blue,
            usesThumbnail: true,
            isLocked: true
        )
        let copyItems = copies.map { file -> ManagerItem in
            ManagerItem(
                id: file.url.path,
                title: file.url.lastPathComponent,
                subtitle: file.url.deletingLastPathComponent().path,
                size: file.size,
                sizeText: ManagerByteText.string(file.size),
                systemImage: "photo.fill",
                tint: .blue,
                usesThumbnail: true
            )
        }
        let items = [keptItem] + copyItems
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
