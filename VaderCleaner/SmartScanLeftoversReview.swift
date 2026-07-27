// SmartScanLeftoversReview.swift
// App leftovers Review for Smart Scan — the shared three-pane manager over orphaned support files of uninstalled apps, opt-in per app with the files revealed as children.

import SwiftUI

/// Holds the id→group lookup the selection callbacks need. Built on the same
/// background pass as the section model so the main thread never rebuilds it;
/// read on the main actor once that build has finished. (A computed dictionary
/// in `body` instead rebuilds the whole index on every render of the hosting
/// dashboard.)
private final class LeftoversReviewLookups: @unchecked Sendable {
    var groupsByID: [String: LeftoverGroup] = [:]
}

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

    @State private var lookups = LeftoversReviewLookups()

    var body: some View {
        let lookups = self.lookups
        let groups = self.groups
        SmartScanReviewManager(
            title: String(
                localized: "Files Left Behind",
                comment: "Title on the Smart Scan app leftovers Review screen."
            ),
            buildSections: {
                lookups.groupsByID = Dictionary(
                    groups.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a }
                )
                return Self.buildSections(groups: groups)
            },
            isSelected: { id in
                guard let group = lookups.groupsByID[id] else { return false }
                return viewModel.isLeftoverSelected(group)
            },
            onToggle: { id in
                guard let group = lookups.groupsByID[id] else { return }
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
                // O(selection), not O(all groups): sum sizes of just the
                // checked ids through the prebuilt lookup.
                let selection = viewModel.leftoverSelection
                let bytes = selection.reduce(Int64(0)) { $0 + (lookups.groupsByID[$1]?.totalBytes ?? 0) }
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
