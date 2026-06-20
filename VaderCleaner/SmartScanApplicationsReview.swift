// SmartScanApplicationsReview.swift
// Applications "Manager" for Smart Scan — the shared three-pane manager over available updates, grouped by update channel, with per-update selection.

import SwiftUI

/// Applications Review, rendered through the shared `SmartScanReviewManager`.
/// Updates are grouped into App Store vs. other (Sparkle) channels; selection
/// bridges to the view model's per-update API.
struct SmartScanApplicationsReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onBack: () -> Void

    private var updatesByID: [String: UpdateInfo] {
        Dictionary(result.availableUpdates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let updates = updatesByID
        let allUpdates = result.availableUpdates
        SmartScanReviewManager(
            title: String(
                localized: "Applications Manager",
                comment: "Title on the Smart Scan Applications Review screen."
            ),
            buildSections: { Self.buildSections(updates: allUpdates) },
            isSelected: { id in
                guard let update = updates[id] else { return false }
                return viewModel.isUpdateSelected(update)
            },
            onToggle: { id in
                guard let update = updates[id] else { return }
                viewModel.toggleUpdate(update)
            },
            onSetCategory: { _, selected in
                viewModel.setAllUpdates(selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.applications"
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
