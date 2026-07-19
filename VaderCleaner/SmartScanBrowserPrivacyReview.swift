// SmartScanBrowserPrivacyReview.swift
// Browser privacy Review for Smart Scan — the shared three-pane manager over per-browser privacy counts. Clearable categories are opt-in rows; awareness-only counts appear in the header copy.

import SwiftUI

/// Browser Privacy Review, rendered through the shared
/// `SmartScanReviewManager`. One middle-pane category per installed browser;
/// its rows are the *clearable* privacy categories (cookies, downloads
/// history, cached files, tabs), selected whole-category per browser.
/// Awareness-only data (passwords, autofill, history, searches) is never a
/// selectable row — it is summarized in the browser's header line, with the
/// Protection section owning the finer-grained tools.
struct SmartScanBrowserPrivacyReview: View {
    var viewModel: SmartScanViewModel
    let summaries: [BrowserPrivacySummary]
    let onBack: () -> Void

    var body: some View {
        let summaries = self.summaries
        SmartScanReviewManager(
            title: String(
                localized: "Browsing Traces",
                comment: "Title on the Smart Scan browser privacy Review screen."
            ),
            buildSections: { Self.buildSections(summaries: summaries) },
            isSelected: { id in
                guard let key = Self.key(fromRowID: id) else { return false }
                return viewModel.isBrowserPrivacySelected(key)
            },
            onToggle: { id in
                guard let key = Self.key(fromRowID: id) else { return }
                viewModel.toggleBrowserPrivacy(key)
            },
            onSetCategory: { category, selected in
                for item in category.items {
                    guard let key = Self.key(fromRowID: item.id) else { continue }
                    if viewModel.isBrowserPrivacySelected(key) != selected {
                        viewModel.toggleBrowserPrivacy(key)
                    }
                }
            },
            onBack: onBack,
            accessibilityPrefix: "smartScan.review.browserPrivacy",
            lightSurface: true,
            selectionSummary: {
                ManagerSelectionSummary(count: viewModel.browserPrivacySelection.count, bytes: nil)
            }
        )
    }

    /// Row ids are "browserRaw|categoryRaw" so the closures can bridge back
    /// to the pair-keyed selection without a lookup table.
    nonisolated private static func rowID(_ browser: Browser, _ category: ProtectionPrivacyCategory) -> String {
        "\(browser.rawValue)|\(category.rawValue)"
    }

    nonisolated private static func key(fromRowID id: String) -> BrowserPrivacyKey? {
        let parts = id.split(separator: "|", maxSplits: 1)
        guard parts.count == 2,
              let browser = Browser(rawValue: String(parts[0])),
              let category = ProtectionPrivacyCategory(rawValue: String(parts[1])) else { return nil }
        return BrowserPrivacyKey(browser: browser, category: category)
    }

    nonisolated private static func buildSections(summaries: [BrowserPrivacySummary]) -> [ManagerSection] {
        let categories = summaries.compactMap { browserCategory(for: $0) }
        guard !categories.isEmpty else { return [] }
        return [ManagerSection(
            id: "browserPrivacy",
            title: String(localized: "Browsers", comment: "Browser privacy Review left-pane section title."),
            categories: categories,
            description: String(
                localized: "Clearing signs you out of websites but never touches passwords or bookmarks.",
                comment: "Header explaining what clearing browser data does and doesn't do."
            )
        )]
    }

    /// SF Symbol per clearable category (the Protection Manager's glossy
    /// badge assets are tuned for its own dark cards, not these light rows).
    nonisolated private static func symbol(for category: ProtectionPrivacyCategory) -> String {
        switch category {
        case .cookies: return "birthday.cake.fill"
        case .downloadsHistory: return "arrow.down.circle.fill"
        case .cachedFiles: return "internaldrive.fill"
        case .tabsFromLastSession: return "macwindow.on.rectangle"
        case .autofillValues, .browsingHistory, .savedPasswords, .searchQueries:
            return "info.circle"
        }
    }

    /// One category per browser: rows for its clearable data, a header line
    /// summarizing the awareness-only counts.
    nonisolated private static func browserCategory(for summary: BrowserPrivacySummary) -> ManagerCategory? {
        let clearable = ProtectionPrivacyCategory.allCases.filter {
            $0.kind == .removable && (summary.counts[$0] ?? 0) > 0
        }
        let informationalCount = ProtectionPrivacyCategory.allCases
            .filter { $0.kind == .informational }
            .reduce(0) { $0 + (summary.counts[$1] ?? 0) }
        guard !clearable.isEmpty || informationalCount > 0 else { return nil }

        let items = clearable.map { category -> ManagerItem in
            let count = summary.counts[category] ?? 0
            return ManagerItem(
                id: rowID(summary.browser, category),
                title: category.displayName,
                subtitle: String.localizedStringWithFormat(
                    String(localized: "%d items", comment: "Browser privacy row subtitle: item count."),
                    count
                ),
                size: nil,
                sizeText: nil,
                systemImage: symbol(for: category),
                tint: .blue
            )
        }
        var category = ManagerCategory(
            id: summary.browser.rawValue,
            title: summary.browser.displayName,
            systemImage: "globe",
            tint: .blue,
            items: items,
            totalSize: nil,
            totalSizeText: nil
        )
        if informationalCount > 0 {
            category.description = String.localizedStringWithFormat(
                String(
                    localized: "Also found %d saved items (history, passwords, autofill) — shown for awareness in the Protection section.",
                    comment: "Browser privacy header noting awareness-only counts handled by Protection."
                ),
                informationalCount
            )
        }
        return category
    }
}
