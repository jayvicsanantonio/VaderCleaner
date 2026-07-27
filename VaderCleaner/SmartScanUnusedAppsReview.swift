// SmartScanUnusedAppsReview.swift
// Unused apps Review for Smart Scan — the shared three-pane manager over long-unopened apps, opt-in per app with real app icons, last-opened dates, and sizes.

import SwiftUI

/// Holds the id→app lookup the selection callbacks need. Built on the same
/// background pass as the section model so the main thread never rebuilds it;
/// read on the main actor once that build has finished. (A computed dictionary
/// in `body` instead rebuilds the whole index on every render of the hosting
/// dashboard.)
private final class UnusedAppsReviewLookups: @unchecked Sendable {
    var appsByID: [String: UnusedApp] = [:]
}

/// Unused Apps Review, rendered through the shared `SmartScanReviewManager`.
/// Removal moves the app bundle to the Trash (restorable), and nothing is
/// pre-checked — apps are the user's own choices.
struct SmartScanUnusedAppsReview: View {
    var viewModel: SmartScanViewModel
    let apps: [UnusedApp]
    let onBack: () -> Void

    @State private var lookups = UnusedAppsReviewLookups()

    var body: some View {
        let lookups = self.lookups
        let apps = self.apps
        SmartScanReviewManager(
            title: String(
                localized: "Apps You Never Open",
                comment: "Title on the Smart Scan unused apps Review screen."
            ),
            buildSections: {
                lookups.appsByID = Dictionary(
                    apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
                )
                return Self.buildSections(apps: apps)
            },
            isSelected: { id in
                guard let app = lookups.appsByID[id] else { return false }
                return viewModel.isUnusedAppSelected(app)
            },
            onToggle: { id in
                guard let app = lookups.appsByID[id] else { return }
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
                // O(selection), not O(all apps): sum sizes of just the checked
                // ids through the prebuilt lookup.
                let selection = viewModel.unusedAppSelection
                let bytes = selection.reduce(Int64(0)) { $0 + (lookups.appsByID[$1]?.sizeBytes ?? 0) }
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

    /// Shared formatter — construction is expensive and the builder runs it
    /// once per row.
    nonisolated private static func subtitle(for unused: UnusedApp) -> String {
        let ago = RelativeDateText.string(for: unused.lastUsedDate)
        return String.localizedStringWithFormat(
            String(localized: "Last opened %@", comment: "Unused app row subtitle: relative last-opened date."),
            ago
        )
    }
}
