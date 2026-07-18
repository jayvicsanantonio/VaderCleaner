// SmartScanPerformanceReview.swift
// Performance "Manager" for Smart Scan — the shared three-pane manager in read-only mode over the login items, with an "Open Performance" jump-link in the footer.

import SwiftUI

/// Performance / Performance Review, rendered through the shared
/// `SmartScanReviewManager` in read-only mode. The actionable work — running
/// the maintenance scripts — is the whole tile, not a per-item selection, so
/// the login-item list is informational (no checkboxes). The footer's
/// "Open Performance" jump-link sends the user to the standalone screen.
struct SmartScanPerformanceReview: View {
    let loginItems: [LoginItem]
    let onBack: () -> Void
    let onOpenPerformance: () -> Void

    var body: some View {
        let items = loginItems
        SmartScanReviewManager(
            title: String(
                localized: "Performance Manager",
                comment: "Title on the Smart Scan Performance Review screen."
            ),
            buildSections: { Self.buildSections(loginItems: items) },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.performance",
            showsSelection: false,
            // Read-only tile: white surface for consistency, but no
            // "smart suggestion" sparkle — its rows carry no clean action.
            lightSurface: true,
            secondaryActionTitle: String(
                localized: "Open Performance",
                comment: "Button on the Smart Scan Performance Review that jumps to the standalone Performance screen."
            ),
            onSecondaryAction: onOpenPerformance
        )
    }

    nonisolated private static func buildSections(loginItems: [LoginItem]) -> [ManagerSection] {
        let items = loginItems.map { item in
            ManagerItem(
                id: item.id,
                title: item.name,
                subtitle: item.isEnabled
                    ? String(localized: "Enabled", comment: "Status label for a login item enabled at boot.")
                    : String(localized: "Disabled", comment: "Status label for a login item disabled at boot."),
                size: nil,
                sizeText: nil,
                systemImage: "power",
                tint: .orange
            )
        }
        guard !items.isEmpty else { return [] }
        return [ManagerSection(
            id: "performance",
            title: String(localized: "Performance", comment: "Performance Manager left-pane section title."),
            categories: [ManagerCategory(
                id: "loginItems",
                title: String(localized: "Login Items", comment: "Performance Manager category for the read-only login-item list."),
                systemImage: "powerplug.fill",
                tint: .orange,
                items: items,
                totalSize: nil,
                totalSizeText: nil
            )]
        )]
    }
}
