// SmartScanUnsupportedAppsReview.swift
// Unsupported apps Review for Smart Scan — the shared three-pane manager over apps incompatible with this macOS, opt-in per app with real app icons. Removal moves the bundle to the Trash.

import SwiftUI

/// Unsupported Apps Review, rendered through the shared `SmartScanReviewManager`.
/// These apps can't launch on this version of macOS, so removing one just
/// reclaims its space. Removal moves the bundle to the Trash (restorable), and
/// nothing is pre-checked — apps are the user's own choices.
struct SmartScanUnsupportedAppsReview: View {
    var viewModel: SmartScanViewModel
    let apps: [UnsupportedApp]
    let onBack: () -> Void

    private var appsByID: [String: UnsupportedApp] {
        Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let appsByID = self.appsByID
        let apps = self.apps
        SmartScanReviewManager(
            title: String(
                localized: "Apps That Won't Run",
                comment: "Title on the Smart Scan unsupported apps Review screen."
            ),
            buildSections: { Self.buildSections(apps: apps) },
            isSelected: { id in
                guard let app = appsByID[id] else { return false }
                return viewModel.isUnsupportedAppSelected(app)
            },
            onToggle: { id in
                guard let app = appsByID[id] else { return }
                viewModel.toggleUnsupportedApp(app)
            },
            onSetCategory: { category, selected in
                viewModel.setUnsupportedApps(category.items.map(\.id), selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.unsupportedApps",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                // Incompatible apps carry no measured size, so the summary is a
                // plain count with no byte credit.
                ManagerSelectionSummary(count: viewModel.unsupportedAppSelection.count, bytes: 0)
            }
        )
    }

    nonisolated private static func buildSections(apps: [UnsupportedApp]) -> [ManagerSection] {
        guard !apps.isEmpty else { return [] }
        let items = apps
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
            .map { app -> ManagerItem in
                ManagerItem(
                    id: app.id,
                    title: app.app.name,
                    subtitle: String(
                        localized: "Not compatible with this version of macOS",
                        comment: "Unsupported app row subtitle."
                    ),
                    size: nil,
                    sizeText: nil,
                    systemImage: "exclamationmark.app.fill",
                    tint: .blue,
                    usesFileIcon: true
                )
            }
        var category = ManagerCategory(
            id: "unsupportedApps",
            title: String(localized: "Incompatible Apps", comment: "Unsupported apps Review category title."),
            systemImage: "exclamationmark.triangle.fill",
            tint: .blue,
            items: items,
            totalSize: 0,
            totalSizeText: nil
        )
        category.description = String(
            localized: "These apps can't open on this Mac. Removing one moves it to the Trash — restore it if you ever need it.",
            comment: "Header explaining unsupported-app removal is restorable."
        )
        return [ManagerSection(
            id: "applications",
            title: String(localized: "Applications", comment: "Unsupported apps Review left-pane section title."),
            categories: [category]
        )]
    }
}
