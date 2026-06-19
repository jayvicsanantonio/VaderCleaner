// SmartScanJunkReview.swift
// System Junk "Cleanup Manager" for Smart Scan — a three-pane (sections → categories → files) manager with per-file selection, search, sort, and a live selected-count footer.

import SwiftUI

/// System Junk Review, rendered through the shared `SmartScanReviewManager`.
/// Builds the section/category/file hierarchy from the scan result and bridges
/// the manager's selection callbacks to the view model's per-file junk
/// selection.
struct SmartScanJunkReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onBack: () -> Void

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

    /// Flat lookup from a manager item's id (the file's path) back to its
    /// `ScannedFile`, so the selection callbacks can reach the view model's
    /// per-file API in O(1).
    private var filesByID: [String: ScannedFile] {
        Dictionary(result.junkResult.items.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Byte size keyed by file URL, so the footer's selected-bytes total is an
    /// O(selected) sum over the selection set rather than an O(all-files) scan
    /// on every checkbox tap.
    private var sizeByURL: [URL: Int64] {
        Dictionary(result.junkResult.items.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
    }

    private var sections: [ManagerSection] {
        Self.groups.compactMap { group in
            let categories = group.categories.compactMap { managerCategory(for: $0) }
            guard !categories.isEmpty else { return nil }
            return ManagerSection(id: group.id, title: group.title, categories: categories)
        }
    }

    var body: some View {
        let files = filesByID
        let sizes = sizeByURL
        SmartScanReviewManager(
            title: String(
                localized: "Cleanup Manager",
                comment: "Title on the Smart Scan System Junk Review screen."
            ),
            sections: sections,
            isSelected: { id in
                guard let file = files[id] else { return false }
                return viewModel.isJunkFileSelected(file)
            },
            onToggle: { id in
                guard let file = files[id] else { return }
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
                let bytes = selection.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    private func managerCategory(for category: ScanCategory) -> ManagerCategory? {
        guard let files = result.junkResult.itemsByCategory[category], !files.isEmpty else { return nil }
        return ManagerCategory(
            id: category.rawValue,
            title: category.displayName,
            systemImage: Self.icon(for: category),
            iconColor: .green,
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

    /// SF Symbol for each junk category's middle-pane row.
    private static func icon(for category: ScanCategory) -> String {
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
