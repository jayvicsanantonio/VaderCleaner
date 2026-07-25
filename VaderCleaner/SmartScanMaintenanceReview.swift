// SmartScanMaintenanceReview.swift
// Tune-up "Manager" for Smart Scan — the shared three-pane manager over the due maintenance tasks, with per-task selection.

import SwiftUI

/// Maintenance Review, rendered through the shared `SmartScanReviewManager`.
/// The tune-up tile is pre-approved, so every due task starts checked; the
/// user can opt a task out here before running. Rows are drawn from the
/// `MaintenanceTask` catalog so each carries its real title, summary, and icon.
struct SmartScanMaintenanceReview: View {
    var viewModel: SmartScanViewModel
    let taskIDs: [String]
    let onBack: () -> Void

    var body: some View {
        let taskIDs = self.taskIDs
        SmartScanReviewManager(
            title: String(
                localized: "Tune-up Manager",
                comment: "Title on the Smart Scan maintenance Review screen."
            ),
            buildSections: { Self.buildSections(taskIDs: taskIDs) },
            isSelected: { id in viewModel.isMaintenanceTaskSelected(id) },
            onToggle: { id in viewModel.toggleMaintenanceTask(id) },
            onSetCategory: { _, selected in
                viewModel.setAllMaintenanceTasks(selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.maintenance",
            lightSurface: true,
            showsSparkle: true
        )
    }

    /// The due tasks in catalog order, mapped to manager rows. Any task ID
    /// without a catalog entry is skipped rather than shown without metadata.
    nonisolated private static func buildSections(taskIDs: [String]) -> [ManagerSection] {
        let due = Set(taskIDs)
        let items = MaintenanceTask.catalog
            .filter { due.contains($0.id) }
            .map { task in
                ManagerItem(
                    id: task.id,
                    title: task.title,
                    subtitle: task.summary,
                    size: nil,
                    sizeText: nil,
                    systemImage: task.icon,
                    tint: .orange
                )
            }
        guard !items.isEmpty else { return [] }
        var category = ManagerCategory(
            id: "maintenance",
            title: String(localized: "Tune-up", comment: "Maintenance Review category title."),
            systemImage: "sparkles",
            tint: .orange,
            items: items,
            totalSize: nil,
            totalSizeText: nil
        )
        category.description = String(
            localized: "Routine upkeep your Mac benefits from every so often. It runs in the background and frees no disk space.",
            comment: "Header explaining the due maintenance tasks."
        )
        return [ManagerSection(
            id: "maintenance",
            title: String(localized: "Maintenance", comment: "Maintenance Review left-pane section title."),
            categories: [category]
        )]
    }
}
