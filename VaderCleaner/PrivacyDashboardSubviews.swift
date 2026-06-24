// PrivacyDashboardSubviews.swift
// Post-scan dashboard for the Privacy section — the "We found X" header, the per-category summary card grid, and the Privacy Manager catalog with its pinned Clear bar.

import AppKit
import SwiftUI

// MARK: - Dashboard

/// The Privacy landing surface after a scan: a headline total, a "View All
/// Data" affordance, and up to four recommendation cards (per-category
/// findings plus a System card for Recent Items) — mirroring the Applications
/// dashboard's hero + adaptive grid so the app's card surfaces stay
/// consistent. The full per-browser breakdown lives in the catalog behind
/// "View All Data".
struct PrivacyDashboardView: View {
    let browserCount: Int
    let totalFoundSize: Int64
    /// Categories with findings, largest first — the first entry renders as
    /// the tall hero card. Supplied by `PrivacyViewModel.dashboardCategories()`.
    let categories: [PrivacyCategory]
    let categorySize: (PrivacyCategory) -> Int64
    let onReviewCategory: (PrivacyCategory) -> Void
    let onReviewSystem: () -> Void
    let onViewAllData: () -> Void
    let onRescan: () -> Void

    /// At most this many cards render on the dashboard — the rest of the
    /// findings stay reachable through the "View All Data" catalog. Matches
    /// the Performance dashboard's curated-recommendations feel.
    private static let maxCards = 4

    /// Fixed width of the right-hand hero column so it keeps a stable shape while
    /// the left tiles absorb the remaining width.
    private let heroColumnWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 16) {
            header
            cardLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("privacy.dashboard")
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text(headlineText)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("privacy.foundTotal")
            Text(categoryCountText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(action: onViewAllData) {
                    Text(String(
                        localized: "View All Data",
                        comment: "Button that opens the full browsing-data catalog."
                    ))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("privacy.viewAllData")

                Button(action: onRescan) {
                    Text(String(
                        localized: "Re-scan",
                        comment: "Button that re-runs the Privacy scan."
                    ))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("privacy.rescan")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// One dashboard card's content. Built as data so the layout can promote
    /// the first one to a tall hero and flow the rest through an adaptive
    /// grid, mirroring the Applications dashboard.
    private struct CardSpec: Identifiable {
        let id: String
        let title: String
        let metric: String
        let detail: String
        let icon: String
        let actionLabel: String
        let action: () -> Void
    }

    /// One card per category with findings, plus the System card last —
    /// Recent Items has no byte size, so it never competes for the hero slot.
    /// Capped at `maxCards`; the System card is the first one dropped, since
    /// Recent Items stays reachable through the catalog's System pane.
    private var cardSpecs: [CardSpec] {
        Array((categories.map(spec(for:)) + [systemSpec]).prefix(Self.maxCards))
    }

    private func spec(for category: PrivacyCategory) -> CardSpec {
        CardSpec(
            id: "privacy.card.\(category.rawValue)",
            title: category.displayName,
            metric: PrivacyViewFormatting.byteFormatter.string(fromByteCount: categorySize(category)),
            detail: detailText(for: category),
            icon: icon(for: category),
            actionLabel: reviewLabel,
            action: { onReviewCategory(category) }
        )
    }

    private var systemSpec: CardSpec {
        CardSpec(
            id: "privacy.card.system",
            title: String(
                localized: "System Traces",
                comment: "Privacy dashboard card title for system-level cleanup (Recent Items)."
            ),
            metric: String(
                localized: "Recent Items",
                comment: "Privacy System Traces card metric naming what it clears."
            ),
            detail: String(
                localized: "The Apple-menu Recent Items list and this app's recent documents.",
                comment: "Privacy System Traces card detail."
            ),
            icon: "clock",
            actionLabel: reviewLabel,
            action: onReviewSystem
        )
    }

    /// Privacy's own layout: the heaviest category is a tall hero pinned to the
    /// right, and the remaining cards divide the left side into equal-height rows
    /// of two. Bounded so the dashboard fills the pane without scrolling.
    @ViewBuilder
    private var cardLayout: some View {
        if cardSpecs.count <= 1 {
            if let hero = cardSpecs.first {
                card(hero, isHero: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                tileRows(Array(cardSpecs.dropFirst()))
                card(cardSpecs[0], isHero: true)
                    .frame(width: heroColumnWidth)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    /// The non-hero cards in equal-height rows of two, grouped in a
    /// `GlassEffectContainer` so neighbouring glass cards refract together.
    private func tileRows(_ specs: [CardSpec]) -> some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 16) {
                ForEach(Array(rows(of: specs).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 16) {
                        ForEach(row) { spec in
                            card(spec, isHero: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Chunks the non-hero specs into rows of at most two so the left band fills
    /// the height beside the hero.
    private func rows(of specs: [CardSpec]) -> [[CardSpec]] {
        stride(from: 0, to: specs.count, by: 2).map {
            Array(specs[$0..<min($0 + 2, specs.count)])
        }
    }

    private func card(_ spec: CardSpec, isHero: Bool) -> some View {
        ApplicationsCard(
            title: spec.title,
            metric: spec.metric,
            detail: spec.detail,
            icon: spec.icon,
            actionLabel: spec.actionLabel,
            identifier: spec.id,
            isHero: isHero,
            action: spec.action
        )
    }

    // MARK: Copy

    private var headlineText: String {
        if browserCount == 0 {
            return String(
                localized: "No browsers were detected on your Mac.",
                comment: "Privacy dashboard headline when the scan found no installed browsers."
            )
        }
        let format = String(
            localized: "We've found %1$@ of browsing data across %2$lld browsers.",
            comment: "Privacy dashboard headline; %1$@ is the total size, %2$lld the browser count."
        )
        return String.localizedStringWithFormat(
            format,
            PrivacyViewFormatting.byteFormatter.string(fromByteCount: totalFoundSize),
            Int64(browserCount)
        )
    }

    private var categoryCountText: String {
        let format = String(
            localized: "%lld data categories with findings.",
            comment: "Privacy dashboard subtitle; %lld is the number of data categories that have findings."
        )
        return String.localizedStringWithFormat(format, Int64(categories.count))
    }

    private var reviewLabel: String {
        String(localized: "Review", comment: "Privacy card action that opens a review screen.")
    }

    private func icon(for category: PrivacyCategory) -> String {
        switch category {
        case .history:    return "clock.arrow.circlepath"
        case .downloads:  return "arrow.down.circle"
        case .cookies:    return "lock.shield"
        case .cache:      return "internaldrive"
        case .savedForms: return "rectangle.and.pencil.and.ellipsis"
        }
    }

    private func detailText(for category: PrivacyCategory) -> String {
        privacyCategoryDetailText(category)
    }
}

/// What each category contains and the consequence of clearing it. Shared by
/// the dashboard cards and the catalog's pane descriptions so the two
/// surfaces never drift apart.
private func privacyCategoryDetailText(_ category: PrivacyCategory) -> String {
    switch category {
    case .history:
        return String(
            localized: "A record of the pages you've visited. On most browsers this also includes download history.",
            comment: "Privacy Browsing History card detail."
        )
    case .downloads:
        return String(
            localized: "The list of files you've downloaded from the web.",
            comment: "Privacy Download History card detail."
        )
    case .cookies:
        return String(
            localized: "Site logins, preferences, and trackers. Clearing signs you out of most websites.",
            comment: "Privacy Cookies card detail, warning about the sign-out consequence."
        )
    case .cache:
        return String(
            localized: "Temporary files browsers keep to load sites faster. Safe to clear — pages just load slower the first time.",
            comment: "Privacy Cached Data card detail."
        )
    case .savedForms:
        return String(
            localized: "Autofill entries like names, addresses, and search terms.",
            comment: "Privacy Saved Form Data card detail."
        )
    }
}

/// A browser's real app icon, read through the shared `AppIconCache`. Falls
/// back to a generic globe when the bundle URL couldn't be resolved (the
/// cache's own placeholder only kicks in for un-preloaded URLs).
struct PrivacyBrowserIcon: View {
    let browser: Browser
    var iconCache: AppIconCache
    let bundleURL: URL?
    let side: CGFloat

    var body: some View {
        Group {
            if let bundleURL {
                Image(nsImage: iconCache.icon(for: bundleURL))
                    .resizable()
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel(Text(browser.displayName))
    }
}

/// One selectable data row: a checkbox, the browser's icon and name, and the
/// cell's size.
struct PrivacyCheckRow: View {
    let browser: Browser
    var iconCache: AppIconCache
    let bundleURL: URL?
    let sizeBytes: Int64
    @Binding var isChecked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(browser.displayName))
            PrivacyBrowserIcon(browser: browser, iconCache: iconCache, bundleURL: bundleURL, side: 28)
            Text(browser.displayName)
                .font(.body)
            Spacer()
            Text(PrivacyViewFormatting.byteFormatter.string(fromByteCount: sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Row rendered for cells whose data is coupled to Browsing History at the
/// file level and therefore can't be cleared independently.
struct PrivacyCoupledRow: View {
    let browser: Browser
    var iconCache: AppIconCache
    let bundleURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 16)
            PrivacyBrowserIcon(browser: browser, iconCache: iconCache, bundleURL: bundleURL, side: 28)
            Text(browser.displayName)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(
                localized: "Included with Browsing History",
                comment: "Explanation for why a privacy data cell cannot be cleared independently."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Data catalog

/// The catalog reached from "View All Data" and from every card's Review
/// button, modelled on Performance's Performance Manager: a back affordance,
/// a left sub-navigation (one item per data category, plus System), a detail
/// pane listing each detected browser's data for that category as a
/// multi-select checklist, and a pinned Clear bar with the running selection
/// total. A Review click opens it on the matching category pane.
struct PrivacyDataCatalogView: View {

    /// The catalog panes the sub-navigation switches between.
    enum Pane: Hashable {
        case category(PrivacyCategory)
        case system
    }

    /// Which pane is shown. Bound to the owning view so a dashboard card or
    /// the View All Data button can open the catalog on a specific pane.
    @Binding var pane: Pane
    let browsers: [Browser]
    /// Icon cache + per-browser bundle-URL resolver for the row icons,
    /// shared with the dashboard so each icon loads once.
    var iconCache: AppIconCache
    let bundleURL: (Browser) -> URL?
    let categorySize: (Browser, PrivacyCategory) -> Int64
    let isCategoryActionable: (Browser, PrivacyCategory) -> Bool
    let isCategoryChecked: (Browser, PrivacyCategory) -> Bool
    let onToggleCategory: (Browser, PrivacyCategory) -> Void
    let isClearRecentsChecked: Bool
    let onToggleClearRecents: () -> Void
    let totalSelectedSize: Int64
    let canClear: Bool
    let onClear: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                subNavigation
                    .frame(width: 220)
                    .padding(16)
                Divider()
                VStack(spacing: 0) {
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    clearBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("privacy.catalog")
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: onBack) {
                // HStack(Image, Text) rather than Label so the control surfaces
                // reliably in XCUITest.
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(String(
                        localized: "Back",
                        comment: "Back button returning from the Privacy data catalog to the dashboard."
                    ))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("privacy.backToDashboard")
            Spacer()
            Text(String(
                localized: "Privacy Manager",
                comment: "Title of the View All Data catalog."
            ))
            .font(.headline)
            Spacer()
            // Balances the leading Back button so the title stays centred.
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(16)
    }

    // MARK: Sub-navigation

    private var subNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(PrivacyCategory.allCases) { category in
                navItem(.category(category), category.displayName,
                        "privacy.catalog.nav.\(category.rawValue)")
            }
            navItem(.system,
                    String(localized: "System", comment: "Privacy catalog sub-nav item for system traces."),
                    "privacy.catalog.nav.system")
            Spacer()
        }
    }

    private func navItem(_ target: Pane, _ title: String, _ identifier: String) -> some View {
        Button {
            pane = target
        } label: {
            Text(title)
                .font(.body.weight(pane == target ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    pane == target ? Color.primary.opacity(0.10) : .clear,
                    in: .rect(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        switch pane {
        case .category(let category):
            categoryPane(category)
        case .system:
            systemPane
        }
    }

    private func categoryPane(_ category: PrivacyCategory) -> some View {
        paneScroll(
            heading: category.displayName,
            description: privacyCategoryDetailText(category)
        ) {
            ForEach(browsers) { browser in
                if isCategoryActionable(browser, category) {
                    PrivacyCheckRow(
                        browser: browser,
                        iconCache: iconCache,
                        bundleURL: bundleURL(browser),
                        sizeBytes: categorySize(browser, category),
                        isChecked: Binding(
                            get: { isCategoryChecked(browser, category) },
                            set: { _ in onToggleCategory(browser, category) }
                        )
                    )
                    .accessibilityIdentifier("privacy.row.\(browser.rawValue).\(category.rawValue)")
                } else {
                    PrivacyCoupledRow(
                        browser: browser,
                        iconCache: iconCache,
                        bundleURL: bundleURL(browser)
                    )
                    .accessibilityIdentifier("privacy.row.\(browser.rawValue).\(category.rawValue).coupled")
                }
            }
        }
    }

    private var systemPane: some View {
        paneScroll(
            heading: String(
                localized: "System Traces",
                comment: "Privacy catalog system-pane heading."
            ),
            description: String(
                localized: "Traces macOS keeps outside your browsers.",
                comment: "Privacy catalog system-pane description."
            )
        ) {
            PrivacyRecentItemsRow(
                isChecked: isClearRecentsChecked,
                onToggle: onToggleClearRecents
            )
        }
    }

    private func paneScroll<Content: View>(
        heading: String,
        description: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(heading)
                    .font(.title3.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    content()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    // MARK: Clear bar

    /// Pinned under the detail pane on every catalog pane — the selection is
    /// global across panes, so the total and the destructive Clear travel
    /// with the catalog rather than living on one pane. Mirrors the
    /// Performance catalog's Run bar.
    private var clearBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    localized: "Total selected",
                    comment: "Label above the selected-size total on the Privacy catalog's Clear bar."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(PrivacyViewFormatting.byteFormatter.string(fromByteCount: totalSelectedSize))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("privacy.totalSelected")
            }
            Spacer()
            Button(String(
                localized: "Clear",
                comment: "Button on the Privacy catalog that clears the selected data."
            ), action: onClear)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.vaderProminent)
                .disabled(!canClear)
                .accessibilityIdentifier("privacy.clear")
        }
        .padding(16)
    }
}

#Preview("Privacy Dashboard") {
    ScrollView {
        PrivacyDashboardView(
            browserCount: 3,
            totalFoundSize: 1_200_000_000,
            categories: [.cache, .history, .cookies],
            categorySize: { category in
                switch category {
                case .cache:   return 1_100_000_000
                case .history: return 96_000_000
                default:       return 4_000_000
                }
            },
            onReviewCategory: { _ in },
            onReviewSystem: { },
            onViewAllData: { },
            onRescan: { }
        )
        .padding(24)
    }
    .frame(width: 900, height: 600)
}

#Preview("Privacy Catalog") {
    PrivacyDataCatalogView(
        pane: .constant(.category(.cookies)),
        browsers: [.safari, .chrome],
        iconCache: AppIconCache(),
        bundleURL: { _ in nil },
        categorySize: { browser, _ in browser == .safari ? 420_000 : 1_300_000 },
        isCategoryActionable: { _, category in category != .downloads },
        isCategoryChecked: { _, _ in true },
        onToggleCategory: { _, _ in },
        isClearRecentsChecked: true,
        onToggleClearRecents: { },
        totalSelectedSize: 1_720_000,
        canClear: true,
        onClear: { },
        onBack: { }
    )
    .frame(width: 900, height: 600)
}
