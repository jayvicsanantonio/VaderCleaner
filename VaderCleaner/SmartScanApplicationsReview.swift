// SmartScanApplicationsReview.swift
// Applications "Manager" for Smart Scan — the shared three-pane manager over available updates, grouped by update channel, with per-update selection.

import SwiftUI

/// Holds the id→update lookup the selection callbacks need. Built on the same
/// background pass as the section model so the main thread never rebuilds it;
/// read on the main actor once that build has finished. (A computed dictionary
/// in `body` instead rebuilds the whole index on every render of the hosting
/// dashboard.)
private final class ApplicationsReviewLookups: @unchecked Sendable {
    var updatesByID: [String: UpdateInfo] = [:]
}

/// Applications Review, rendered through the shared `SmartScanReviewManager`.
/// Updates are grouped into App Store vs. other (Sparkle) channels; selection
/// bridges to the view model's per-update API.
struct SmartScanApplicationsReview: View {
    var viewModel: SmartScanViewModel
    let allUpdates: [UpdateInfo]
    let onBack: () -> Void

    @State private var lookups = ApplicationsReviewLookups()

    var body: some View {
        let lookups = self.lookups
        let allUpdates = self.allUpdates
        SmartScanReviewManager(
            title: String(
                localized: "Applications Manager",
                comment: "Title on the Smart Scan Applications Review screen."
            ),
            buildSections: {
                lookups.updatesByID = Dictionary(
                    allUpdates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
                )
                return Self.buildSections(updates: allUpdates)
            },
            isSelected: { id in
                guard let update = lookups.updatesByID[id] else { return false }
                return viewModel.isUpdateSelected(update)
            },
            onToggle: { id in
                guard let update = lookups.updatesByID[id] else { return }
                viewModel.toggleUpdate(update)
            },
            onSetCategory: { _, selected in
                viewModel.setAllUpdates(selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.applications",
            lightSurface: true,
            showsSparkle: true
        )
    }

    nonisolated private static func buildSections(updates: [UpdateInfo]) -> [ManagerSection] {
        let categories = [
            category(updates, source: .appStore,
                     id: "appStore",
                     title: String(localized: "App Store", comment: "Applications Manager category for Mac App Store updates."),
                     systemImage: "storefront.fill"),
            category(updates, source: .sparkle,
                     id: "other",
                     title: String(localized: "Other Apps", comment: "Applications Manager category for non-App-Store (Sparkle) updates."),
                     systemImage: "shippingbox.fill"),
        ].compactMap { $0 }
        guard !categories.isEmpty else { return [] }
        return [ManagerSection(
            id: "applications",
            title: String(localized: "Applications", comment: "Applications Manager left-pane section title."),
            categories: categories
        )]
    }

    nonisolated private static func category(
        _ updates: [UpdateInfo],
        source: UpdateSource,
        id: String,
        title: String,
        systemImage: String
    ) -> ManagerCategory? {
        let matching = updates.filter { $0.source == source }
        guard !matching.isEmpty else { return nil }
        return ManagerCategory(
            id: id,
            title: title,
            systemImage: systemImage,
            tint: .purple,
            items: matching.map { update in
                ManagerItem(
                    id: update.id,
                    title: update.appName,
                    subtitle: "\(update.installedVersion) → \(update.latestVersion)",
                    size: nil,
                    sizeText: nil,
                    systemImage: "arrow.down.app.fill",
                    tint: .purple
                )
            },
            totalSize: nil,
            totalSizeText: nil
        )
    }
}
