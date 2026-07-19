// SmartScanLeftoversReview.swift
// App leftovers Review for Smart Scan — the shared three-pane manager over orphaned support files of uninstalled apps, opt-in per app with the files revealed as children.

import SwiftUI

/// Leftovers Review, rendered through the shared `SmartScanReviewManager`.
/// One row per uninstalled app's leftover group. Selection is group-level —
/// the files belong together, and removing half an app's leftovers helps
/// no one — so the row's subtitle carries the file count instead of an
/// expandable tree (child rows would render selection affordances that
/// can't act at the group grain).
struct SmartScanLeftoversReview: View {
    var viewModel: SmartScanViewModel
    let groups: [LeftoverGroup]
    let onBack: () -> Void

    private var groupsByID: [String: LeftoverGroup] {
        Dictionary(groups.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let groupsByID = self.groupsByID
        let groups = self.groups
        SmartScanReviewManager(
            title: String(
                localized: "Files Left Behind",
                comment: "Title on the Smart Scan app leftovers Review screen."
            ),
            buildSections: { Self.buildSections(groups: groups) },
            isSelected: { id in
                guard let group = groupsByID[id] else { return false }
                return viewModel.isLeftoverSelected(group)
            },
            onToggle: { id in
                guard let group = groupsByID[id] else { return }
                viewModel.toggleLeftover(group)
            },
            onSetCategory: { category, selected in
                viewModel.setLeftovers(category.items.map(\.id), selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.appLeftovers",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                let selection = viewModel.leftoverSelection
                let bytes = groups.reduce(Int64(0)) { total, group in
                    selection.contains(group.bundleID) ? total + group.totalBytes : total
                }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    nonisolated private static func buildSections(groups: [LeftoverGroup]) -> [ManagerSection] {
        guard !groups.isEmpty else { return [] }
        let sorted = groups.sorted { $0.totalBytes > $1.totalBytes }
        let items = sorted.map { group -> ManagerItem in
            ManagerItem(
                id: group.bundleID,
                title: group.displayName,
                subtitle: String.localizedStringWithFormat(
                    String(
                        localized: "%d files · %@",
                        comment: "Leftover group row subtitle: file count, bundle identifier."
                    ),
                    group.urls.count, group.bundleID
                ),
                size: group.totalBytes,
                sizeText: ManagerByteText.string(group.totalBytes),
                systemImage: "puzzlepiece.extension.fill",
                tint: .blue
            )
        }
        let total = groups.reduce(Int64(0)) { $0 + $1.totalBytes }
        var category = ManagerCategory(
            id: "leftovers",
            title: String(localized: "Leftover Files", comment: "Leftovers Review category title."),
            systemImage: "puzzlepiece.extension.fill",
            tint: .blue,
            items: items,
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
        category.description = String(
            localized: "Settings and support files from apps that are no longer installed. Removal moves them to the Trash.",
            comment: "Header explaining app leftovers."
        )
        return [ManagerSection(
            id: "applications",
            title: String(localized: "Applications", comment: "Leftovers Review left-pane section title."),
            categories: [category]
        )]
    }
}
