// SmartScanExtensionsReview.swift
// Extensions "Manager" for Smart Scan — the shared three-pane manager in read-only mode over the browser/app extensions found, grouped by type, with an "Open Applications" jump-link. Smart Scan never disables or removes an extension itself.

import SwiftUI

/// Extensions Review, rendered through the shared `SmartScanReviewManager` in
/// read-only mode. Disabling an extension is a deliberate, per-item decision, so
/// Smart Scan surfaces the list but never acts on it — the footer's
/// "Open Applications" jump-link sends the user to the standalone manager.
struct SmartScanExtensionsReview: View {
    let extensions: [ExtensionItem]
    let onBack: () -> Void
    let onOpenApplications: () -> Void

    var body: some View {
        let items = extensions
        SmartScanReviewManager(
            title: String(
                localized: "Extensions",
                comment: "Title on the Smart Scan Extensions Review screen."
            ),
            buildSections: { Self.buildSections(extensions: items) },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.extensions",
            showsSelection: false,
            lightSurface: true,
            secondaryActionTitle: String(
                localized: "Open Applications",
                comment: "Button on the Smart Scan Extensions Review that jumps to the standalone Applications screen."
            ),
            onSecondaryAction: onOpenApplications
        )
    }

    nonisolated private static func buildSections(extensions: [ExtensionItem]) -> [ManagerSection] {
        // One category per extension type (Safari, Chrome, …), preserving the
        // manager's grouping.
        let categories = ExtensionType.allCases.compactMap { type -> ManagerCategory? in
            let ofType = extensions.filter { $0.type == type }
            guard !ofType.isEmpty else { return nil }
            let items = ofType
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { ext in
                    ManagerItem(
                        id: ext.path.path,
                        title: ext.name,
                        subtitle: ext.path.deletingLastPathComponent().path,
                        size: ext.size,
                        sizeText: ext.size > 0 ? ManagerByteText.string(ext.size) : nil,
                        systemImage: "puzzlepiece.extension.fill",
                        tint: .blue
                    )
                }
            let total = ofType.reduce(Int64(0)) { $0 + $1.size }
            return ManagerCategory(
                id: type.rawValue,
                title: type.displayName,
                systemImage: "puzzlepiece.extension.fill",
                tint: .blue,
                items: items,
                totalSize: total,
                totalSizeText: total > 0 ? ManagerByteText.string(total) : nil
            )
        }
        guard !categories.isEmpty else { return [] }
        return [ManagerSection(
            id: "extensions",
            title: String(localized: "Extensions", comment: "Extensions Review left-pane section title."),
            categories: categories,
            description: String(
                localized: "Review anything you don't recognize, then manage it in the Applications screen.",
                comment: "Header for the read-only extensions list."
            )
        )]
    }
}
