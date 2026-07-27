// SmartScanInstallersReview.swift
// Finished installers Review for Smart Scan — the shared three-pane manager over leftover .dmg/.pkg/.iso files, opt-in per installer with Finder icons.

import SwiftUI

/// Holds the id→installer lookup the selection callbacks need. Built on the
/// same background pass as the section model so the main thread never rebuilds
/// it; read on the main actor once that build has finished. (A computed
/// dictionary in `body` instead rebuilds the whole index on every render of the
/// hosting dashboard.)
private final class InstallersReviewLookups: @unchecked Sendable {
    var installersByID: [String: InstallationFile] = [:]
}

/// Installers Review, rendered through the shared `SmartScanReviewManager`.
/// Installer files are the user's own downloads, so nothing is pre-checked;
/// removal moves them to the Trash.
struct SmartScanInstallersReview: View {
    var viewModel: SmartScanViewModel
    let installers: [InstallationFile]
    let onBack: () -> Void

    @State private var lookups = InstallersReviewLookups()

    var body: some View {
        let lookups = self.lookups
        let installers = self.installers
        SmartScanReviewManager(
            title: String(
                localized: "Finished Installers",
                comment: "Title on the Smart Scan installers Review screen."
            ),
            buildSections: {
                lookups.installersByID = Dictionary(
                    installers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
                )
                return Self.buildSections(installers: installers)
            },
            isSelected: { id in
                guard let file = lookups.installersByID[id] else { return false }
                return viewModel.isInstallerSelected(file)
            },
            onToggle: { id in
                guard let file = lookups.installersByID[id] else { return }
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
                // O(selection), not O(all installers): sum sizes of just the
                // checked ids through the prebuilt lookup.
                let selection = viewModel.installerSelection
                let bytes = selection.reduce(Int64(0)) { $0 + (lookups.installersByID[$1]?.sizeBytes ?? 0) }
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
