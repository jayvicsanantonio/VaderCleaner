// SmartScanUnusedAppsReview.swift
// Unused apps Review for Smart Scan — the shared three-pane manager over long-unopened apps, opt-in per app with real app icons, last-opened dates, and sizes.

import SwiftUI

/// Unused Apps Review, rendered through the shared `SmartScanReviewManager`.
/// Removal moves the app bundle to the Trash (restorable), and nothing is
/// pre-checked — apps are the user's own choices.
struct SmartScanUnusedAppsReview: View {
    var viewModel: SmartScanViewModel
    let apps: [UnusedApp]
    let onBack: () -> Void

    private var appsByID: [String: UnusedApp] {
        Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let appsByID = self.appsByID
        let apps = self.apps
        SmartScanReviewManager(
            title: String(
                localized: "Apps You Never Open",
                comment: "Title on the Smart Scan unused apps Review screen."
            ),
            buildSections: { Self.buildSections(apps: apps) },
            isSelected: { id in
                guard let app = appsByID[id] else { return false }
                return viewModel.isUnusedAppSelected(app)
            },
            onToggle: { id in
                guard let app = appsByID[id] else { return }
                viewModel.toggleUnusedApp(app)
            },
            onSetCategory: { category, selected in
                viewModel.setUnusedApps(category.items.map(\.id), selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.unusedApps",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                let selection = viewModel.unusedAppSelection
                let bytes = apps.reduce(Int64(0)) { total, app in
                    selection.contains(app.id) ? total + app.sizeBytes : total
                }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    nonisolated private static func buildSections(apps: [UnusedApp]) -> [ManagerSection] {
        guard !apps.isEmpty else { return [] }
        let sorted = apps.sorted { $0.sizeBytes > $1.sizeBytes }
        let items = sorted.map { unused -> ManagerItem in
            ManagerItem(
                id: unused.id,
                title: unused.app.name,
                subtitle: subtitle(for: unused),
                size: unused.sizeBytes,
                sizeText: ManagerByteText.string(unused.sizeBytes),
                systemImage: "app.fill",
                tint: .blue,
                usesFileIcon: true
            )
        }
        let total = apps.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var category = ManagerCategory(
            id: "unusedApps",
            title: String(localized: "Apps You Haven't Opened", comment: "Unused apps Review category title."),
            systemImage: "square.grid.3x3.slash",
            tint: .blue,
            items: items,
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
        category.description = String(
            localized: "Removing an app moves it to the Trash — you can always reinstall it later.",
            comment: "Header explaining unused-app removal is restorable."
        )
        return [ManagerSection(
            id: "applications",
            title: String(localized: "Applications", comment: "Unused apps Review left-pane section title."),
            categories: [category]
        )]
    }

    nonisolated private static func subtitle(for unused: UnusedApp) -> String {
        let ago = RelativeDateTimeFormatter().localizedString(for: unused.lastUsedDate, relativeTo: Date())
        return String.localizedStringWithFormat(
            String(localized: "Last opened %@", comment: "Unused app row subtitle: relative last-opened date."),
            ago
        )
    }
}
