// SmartScanInstallersReview.swift
// Finished installers Review for Smart Scan — the shared three-pane manager over leftover .dmg/.pkg/.iso files, opt-in per installer with Finder icons.

import SwiftUI

/// Installers Review, rendered through the shared `SmartScanReviewManager`.
/// Installer files are the user's own downloads, so nothing is pre-checked;
/// removal moves them to the Trash.
struct SmartScanInstallersReview: View {
    var viewModel: SmartScanViewModel
    let installers: [InstallationFile]
    let onBack: () -> Void

    private var installersByID: [String: InstallationFile] {
        Dictionary(installers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let installersByID = self.installersByID
        let installers = self.installers
        SmartScanReviewManager(
            title: String(
                localized: "Finished Installers",
                comment: "Title on the Smart Scan installers Review screen."
            ),
            buildSections: { Self.buildSections(installers: installers) },
            isSelected: { id in
                guard let file = installersByID[id] else { return false }
                return viewModel.isInstallerSelected(file)
            },
            onToggle: { id in
                guard let file = installersByID[id] else { return }
                viewModel.toggleInstaller(file)
            },
            onSetCategory: { category, selected in
                viewModel.setInstallers(category.items.map(\.id), selected: selected)
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.installers",
            lightSurface: true,
            showsSparkle: true,
            selectionSummary: {
                let selection = viewModel.installerSelection
                let bytes = installers.reduce(Int64(0)) { total, file in
                    selection.contains(file.id) ? total + file.sizeBytes : total
                }
                return ManagerSelectionSummary(count: selection.count, bytes: bytes)
            }
        )
    }

    nonisolated private static func buildSections(installers: [InstallationFile]) -> [ManagerSection] {
        guard !installers.isEmpty else { return [] }
        let sorted = installers.sorted { $0.sizeBytes > $1.sizeBytes }
        let items = sorted.map { file -> ManagerItem in
            ManagerItem(
                id: file.id,
                title: file.name,
                subtitle: file.url.deletingLastPathComponent().path,
                size: file.sizeBytes,
                sizeText: ManagerByteText.string(file.sizeBytes),
                systemImage: file.kind == .package ? "shippingbox.fill" : "opticaldisc.fill",
                tint: .blue,
                usesFileIcon: true
            )
        }
        let total = installers.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var category = ManagerCategory(
            id: "installers",
            title: String(localized: "Installers", comment: "Installers Review category title."),
            systemImage: "arrow.down.circle.fill",
            tint: .blue,
            items: items,
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
        category.description = String(
            localized: "Disk images and installer packages that already did their job. Removal moves them to the Trash.",
            comment: "Header explaining leftover installers."
        )
        return [ManagerSection(
            id: "applications",
            title: String(localized: "Applications", comment: "Installers Review left-pane section title."),
            categories: [category]
        )]
    }
}
