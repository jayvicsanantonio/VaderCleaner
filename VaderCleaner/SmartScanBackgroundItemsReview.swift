// SmartScanBackgroundItemsReview.swift
// Background Items "Manager" for Smart Scan — the shared three-pane manager in read-only mode over the launch agents/daemons found, with an "Open Performance" jump-link. Smart Scan never disables or removes an agent itself.

import SwiftUI

/// Background Items Review, rendered through the shared `SmartScanReviewManager`
/// in read-only mode. Disabling a launch agent is a deliberate, potentially
/// system-affecting choice, so Smart Scan surfaces the list but never acts on
/// it — the footer's "Open Performance" jump-link sends the user to the
/// standalone screen where each item can be managed safely.
struct SmartScanBackgroundItemsReview: View {
    let agents: [LaunchAgent]
    let onBack: () -> Void
    let onOpenPerformance: () -> Void

    var body: some View {
        let agents = self.agents
        SmartScanReviewManager(
            title: String(
                localized: "Background Items",
                comment: "Title on the Smart Scan Background Items Review screen."
            ),
            buildSections: { Self.buildSections(agents: agents) },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.backgroundItems",
            showsSelection: false,
            lightSurface: true,
            secondaryActionTitle: String(
                localized: "Open Performance",
                comment: "Button on the Smart Scan Background Items Review that jumps to the standalone Performance screen."
            ),
            onSecondaryAction: onOpenPerformance
        )
    }

    nonisolated private static func buildSections(agents: [LaunchAgent]) -> [ManagerSection] {
        let items = agents
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            .map { agent in
                ManagerItem(
                    id: agent.id,
                    title: agent.label,
                    subtitle: agent.isEnabled
                        ? String(localized: "Enabled", comment: "Status label for an enabled background item.")
                        : String(localized: "Disabled", comment: "Status label for a disabled background item."),
                    size: nil,
                    sizeText: nil,
                    systemImage: "gearshape.2.fill",
                    tint: .orange
                )
            }
        guard !items.isEmpty else { return [] }
        return [ManagerSection(
            id: "backgroundItems",
            title: String(localized: "Performance", comment: "Background Items Review left-pane section title."),
            categories: [ManagerCategory(
                id: "backgroundItems",
                title: String(localized: "Background Items", comment: "Background Items Review category title."),
                systemImage: "gearshape.2.fill",
                tint: .orange,
                items: items,
                totalSize: 0,
                totalSizeText: nil
            )],
            description: String(
                localized: "These run quietly in the background. Manage them safely in the Performance screen.",
                comment: "Header for the read-only background-items list."
            )
        )]
    }
}
