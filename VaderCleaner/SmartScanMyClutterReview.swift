// SmartScanMyClutterReview.swift
// My Clutter "Manager" for Smart Scan — the shared three-pane manager over duplicate-file groups. One category per group lists the redundant copies (the kept original is named but never listed, so it can't be deleted). The model is built off the main thread so large scans open without blocking.

import SwiftUI

/// Holds the id→file and url→size lookups the selection callbacks need. Built
/// on the same background task as the section model so nothing O(N) runs on the
/// main thread; read on the main actor once that build has finished.
private final class ClutterReviewLookups: @unchecked Sendable {
    var filesByID: [String: ScannedFile] = [:]
    var sizeByURL: [URL: Int64] = [:]
}

/// My Clutter Review, rendered through the shared `SmartScanReviewManager`.
/// Each duplicate group is one category whose items are the redundant copies;
/// the kept original is named in the category title but never listed, so it can
/// never be selected for deletion. Redundant copies default to selected (a copy
/// always survives), matching Smart Care.
struct SmartScanMyClutterReview: View {
    var viewModel: SmartScanViewModel
    let groups: [DuplicateGroup]
    let onBack: () -> Void

    @State private var lookups = ClutterReviewLookups()

    var body: some View {
        let lookups = self.lookups
        let groups = self.groups
        SmartScanReviewManager(
            title: String(
                localized: "Duplicates Manager",
                comment: "Title on the Smart Scan My Clutter (duplicates) Review screen."
            ),
            buildSections: {
                // Build the selection lookups on the same off-main pass as the
                // section model, so the main thread never does O(all-files) work.
                // Only the redundant copies are deletable, so only they enter the
                // lookups — the kept originals can never be toggled.
                let copies = groups.flatMap { $0.redundantCopies }
                lookups.filesByID = Dictionary(copies.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
                lookups.sizeByURL = Dictionary(copies.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
                return Self.buildSections(groups: groups)
            },
            isSelected: { id in
                guard let file = lookups.filesByID[id] else { return false }
                return viewModel.isDuplicateSelected(file)
            },
            onToggle: { id in
                guard let file = lookups.filesByID[id] else { return }
                viewModel.toggleDuplicate(file)
            },
            onSetCategory: { category, selected in
                let urls = category.items.map { URL(fileURLWithPath: $0.id) }
                viewModel.setDuplicates(urls, selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.myClutter",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                let selection = viewModel.duplicateSelection
                let bytes = selection.reduce(Int64(0)) { $0 + (lookups.sizeByURL[$1] ?? 0) }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    nonisolated private static func buildSections(groups: [DuplicateGroup]) -> [ManagerSection] {
        let categories = groups.compactMap { category(for: $0) }
        guard !categories.isEmpty else { return [] }
        return [ManagerSection(
            id: "duplicates",
            title: String(localized: "Duplicates", comment: "Duplicates Manager left-pane section title."),
            categories: categories
        )]
    }

    /// One category per duplicate group: its items are the redundant copies, and
    /// its title names the original that will be kept.
    nonisolated private static func category(for group: DuplicateGroup) -> ManagerCategory? {
        let copies = group.redundantCopies
        guard !copies.isEmpty else { return nil }
        let items = copies.map { file -> ManagerItem in
            let ext = file.url.pathExtension.lowercased()
            let isImage = SimilarImageScanner.imageExtensions.contains(ext)
            let isDir = ext.isEmpty
            // Image copies show a Quick Look thumbnail so the picture is
            // visible; every other file keeps its tinted doc/folder badge —
            // a rounded photo tile around a .zip or .dmg icon would read wrong.
            return ManagerItem(
                id: file.url.path,
                title: file.url.lastPathComponent,
                subtitle: file.url.deletingLastPathComponent().path,
                size: file.size,
                sizeText: ManagerByteText.string(file.size),
                systemImage: isDir ? "folder.fill" : "doc.on.doc.fill",
                tint: isDir ? .blue : .secondary,
                usesThumbnail: isImage
            )
        }
        let total = group.reclaimableBytes
        let keptName = group.original.url.lastPathComponent
        return ManagerCategory(
            id: group.original.url.path,
            title: String(
                localized: "Copies of “\(keptName)”",
                comment: "Duplicates Manager category title; the named file is the copy that is kept."
            ),
            systemImage: "doc.on.doc.fill",
            tint: .orange,
            items: items,
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
    }
}
