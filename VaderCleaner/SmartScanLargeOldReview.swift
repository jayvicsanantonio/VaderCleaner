// SmartScanLargeOldReview.swift
// Large & forgotten files Review for Smart Scan — the shared three-pane manager over the large/old file findings, opt-in per file with Finder icons and age subtitles.

import SwiftUI

/// Large & Old Files Review, rendered through the shared
/// `SmartScanReviewManager`. Every row is the user's own file, so nothing is
/// pre-checked — the card's selection fills only from explicit choices here.
struct SmartScanLargeOldReview: View {
    var viewModel: SmartScanViewModel
    let files: [ScannedFile]
    let onBack: () -> Void

    /// id (path) → file, for bridging row toggles to the URL-keyed selection.
    private var filesByID: [String: ScannedFile] {
        Dictionary(files.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let filesByID = self.filesByID
        let files = self.files
        SmartScanReviewManager(
            title: String(
                localized: "Large & Forgotten Files",
                comment: "Title on the Smart Scan large/old files Review screen."
            ),
            buildSections: { Self.buildSections(files: files) },
            isSelected: { id in
                guard let file = filesByID[id] else { return false }
                return viewModel.isLargeOldFileSelected(file)
            },
            onToggle: { id in
                guard let file = filesByID[id] else { return }
                viewModel.toggleLargeOldFile(file)
            },
            onSetCategory: { category, selected in
                let urls = category.items.map { URL(fileURLWithPath: $0.id) }
                viewModel.setLargeOldFiles(urls, selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.largeOldFiles",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                let selection = viewModel.largeOldFileSelection
                let bytes = files.reduce(Int64(0)) { total, file in
                    selection.contains(file.url) ? total + file.size : total
                }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    nonisolated private static func buildSections(files: [ScannedFile]) -> [ManagerSection] {
        let categories = [
            category(
                files.filter { $0.category == .largeFile },
                id: "largeFiles",
                title: String(localized: "Large Files", comment: "Large/old Review category for big files."),
                systemImage: "shippingbox.fill",
                description: String(
                    localized: "Files over 50 MB. Big wins if you no longer need them.",
                    comment: "Header explaining the Large Files category."
                )
            ),
            category(
                files.filter { $0.category == .oldFile },
                id: "oldFiles",
                title: String(localized: "Old Files", comment: "Large/old Review category for long-unopened files."),
                systemImage: "clock.fill",
                description: String(
                    localized: "Files you haven't opened in over six months.",
                    comment: "Header explaining the Old Files category."
                )
            ),
        ].compactMap { $0 }
        guard !categories.isEmpty else { return [] }
        return [ManagerSection(
            id: "largeOld",
            title: String(localized: "My Clutter", comment: "Large/old Review left-pane section title."),
            categories: categories,
            description: String(
                localized: "These are your files — nothing is removed unless you check it.",
                comment: "Header reminding that large/old files are opt-in."
            )
        )]
    }

    nonisolated private static func category(
        _ files: [ScannedFile],
        id: String,
        title: String,
        systemImage: String,
        description: String
    ) -> ManagerCategory? {
        guard !files.isEmpty else { return nil }
        let sorted = files.sorted { $0.size > $1.size }
        let items = sorted.map { file -> ManagerItem in
            ManagerItem(
                id: file.url.path,
                title: file.url.lastPathComponent,
                subtitle: subtitle(for: file),
                size: file.size,
                sizeText: ManagerByteText.string(file.size),
                systemImage: "doc.fill",
                tint: .blue,
                usesFileIcon: true
            )
        }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var category = ManagerCategory(
            id: id,
            title: title,
            systemImage: systemImage,
            tint: .blue,
            items: items,
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
        category.description = description
        return category
    }

    /// "Last opened 8 months ago · ~/Movies" — the two facts a person needs
    /// to decide whether a file still matters.
    nonisolated private static func subtitle(for file: ScannedFile) -> String {
        let folder = file.url.deletingLastPathComponent().path
        guard let accessed = file.lastAccessDate else { return folder }
        let ago = RelativeDateTimeFormatter().localizedString(for: accessed, relativeTo: Date())
        return String.localizedStringWithFormat(
            String(
                localized: "Last opened %@ · %@",
                comment: "Large/old file row subtitle: relative last-opened date, containing folder."
            ),
            ago, folder
        )
    }
}
