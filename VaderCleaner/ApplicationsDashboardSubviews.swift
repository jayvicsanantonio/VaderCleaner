// ApplicationsDashboardSubviews.swift
// Post-scan dashboard for the Applications section — the "N apps found" header, the summary card grid, and the progress / failed states.

import SwiftUI

// MARK: - Dashboard

/// The Applications landing surface after a scan: a headline count, a "Manage
/// My Applications" affordance, and the summary cards in an adaptive grid —
/// mirroring the Performance dashboard's card layout.
struct ApplicationsDashboardView: View {
    let result: ApplicationsScanResult
    var iconCache: AppIconCache
    /// Section accent, used to tint any reassurance backfill cards.
    let accent: Color
    let onOpenManage: () -> Void
    let onOpenInstallationFiles: () -> Void
    let onOpenUnsupported: () -> Void
    let onOpenUnused: () -> Void
    let onOpenUpdates: () -> Void
    let onOpenLeftovers: () -> Void
    /// One-click removal for the App Leftovers card's Remove button — selects
    /// every leftover group and moves it to the Trash.
    let onRemoveLeftovers: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            header
            // The grid stays flexible (it absorbs any height squeeze) so the
            // hero keeps its standard size instead of being compressed.
            cardLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.dashboard")
        .task(id: result.unusedApps.map(\.id)) {
            // Preload the unused apps' icons for the Unused card's icon cluster.
            // Their on-disk sizes are already summed by the scan, so the detail
            // line's total is available on first paint.
            let urls = result.unusedApps.map { $0.app.bundleURL }
            await iconCache.preloadIcons(for: urls)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("applications")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 140, maxHeight: 140)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(installedCountText)
                    .font(.title.weight(.semibold))
                    .accessibilityIdentifier("applications.installedCount")
                Text(String(
                    localized: "Use quick recommendations or manage them by hand.",
                    comment: "Applications dashboard subheadline beneath the installed-app count."
                ))
                .font(.title3)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)

            Button(action: onOpenManage) {
                Text(String(
                    localized: "Manage My Applications",
                    comment: "Button that opens the full installed-apps management (uninstaller) list."
                ))
                .padding(.horizontal, 8)
            }
            .buttonStyle(.vaderTileGlass)
            .controlSize(.large)
            .accessibilityIdentifier("applications.manageMyApplications")
        }
    }

    /// One dashboard card's content, built as data so the layout can render the
    /// lead recommendation as a tall left card and stack the rest in a right
    /// column — matching the reference dashboard.
    private struct CardSpec: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: ApplicationsCardIcon
        let primaryLabel: String
        let primaryAction: () -> Void
        /// Optional second action, rendered as a bordered button to the left of
        /// the prominent primary (the App Leftovers card's Review).
        var secondaryLabel: String? = nil
        var secondaryAction: (() -> Void)? = nil
    }

    private var reviewLabel: String {
        String(localized: "Review", comment: "Applications card action that opens a review list.")
    }

    private var removeLabel: String {
        String(localized: "Remove", comment: "Applications card action that removes the finding directly.")
    }

    private func spec(for recommendation: ApplicationsScanResult.Recommendation) -> CardSpec {
        switch recommendation {
        case .unsupported:
            return CardSpec(id: "applications.card.unsupported", title: unsupportedTitle,
                            detail: unsupportedDetail, icon: .symbol("exclamationmark.triangle.fill"),
                            primaryLabel: reviewLabel, primaryAction: onOpenUnsupported)
        case .unused:
            return CardSpec(id: "applications.card.unused", title: unusedTitle,
                            detail: unusedDetail,
                            icon: .appIcons(Array(result.unusedApps.prefix(3).map { $0.app.bundleURL })),
                            primaryLabel: reviewLabel, primaryAction: onOpenUnused)
        case .updates:
            return CardSpec(id: "applications.card.updates", title: updatesTitle,
                            detail: updatesDetail, icon: .symbol("arrow.down.circle.fill"),
                            primaryLabel: updateLabel, primaryAction: onOpenUpdates)
        case .leftovers:
            // Review (bordered) + Remove (prominent), matching the reference card.
            return CardSpec(id: "applications.card.leftovers", title: leftoversTitle,
                            detail: leftoversDetail, icon: .asset("appLeftovers"),
                            primaryLabel: removeLabel, primaryAction: onRemoveLeftovers,
                            secondaryLabel: reviewLabel, secondaryAction: onOpenLeftovers)
        case .installationFiles:
            return CardSpec(id: "applications.card.installationFiles", title: installationFilesTitle,
                            detail: installationFilesDetail, icon: .asset("installerDmg"),
                            primaryLabel: reviewLabel, primaryAction: onOpenInstallationFiles)
        }
    }

    /// The ranked 2–4 cards this scan warrants, most actionable first.
    private var tiles: [ApplicationsDashboardTile] {
        result.recommendedTiles()
    }

    /// The reference layout: the lead card is a tall card on the left, and the
    /// remaining cards sit in a right-hand column packed into rows of two (an odd
    /// count leads with a single full-width row), mirroring the My Clutter
    /// dashboard. Capping the right column at rows of two keeps the grid bounded
    /// so it fills the pane without overflowing, however many cards there are.
    /// Gap between adjacent tiles, shared by the column split and the row split
    /// so the deterministic sizing math matches the visual spacing.
    private let cardGap: CGFloat = 16

    @ViewBuilder
    private var cardLayout: some View {
        let tiles = self.tiles
        if tiles.count <= 1 {
            if let only = tiles.first {
                card(only).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // Size each card concretely from the pane geometry rather than
            // nesting `.frame(maxWidth:.infinity, maxHeight:.infinity)` cards
            // several levels deep. A flexible grid this deep makes the SwiftUI
            // layout engine re-probe every card for many candidate sizes on the
            // first build — the dominant cost when the section is rebuilt after a
            // switch. Concrete frames resolve the whole grid in a single pass.
            // Spacing below the 16pt grid gap so adjacent tiles never blend.
            GlassEffectContainer(spacing: 8) {
                GeometryReader { geo in
                    let columnWidth = (geo.size.width - cardGap) / 2
                    HStack(alignment: .top, spacing: cardGap) {
                        card(tiles[0])
                            .frame(width: columnWidth, height: geo.size.height)
                        rightColumn(
                            Array(tiles.dropFirst()),
                            width: columnWidth,
                            height: geo.size.height
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The right-hand cards, packed into rows of at most two so the column never
    /// grows taller than the pane. Sized concretely from the column geometry so
    /// the grid stays a single-pass layout (see `cardLayout`).
    private func rightColumn(
        _ tiles: [ApplicationsDashboardTile],
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let cardRows = rows(of: tiles)
        let rowHeight = (height - cardGap * CGFloat(cardRows.count - 1)) / CGFloat(max(cardRows.count, 1))
        return VStack(spacing: cardGap) {
            ForEach(cardRows) { row in
                let cardWidth = (width - cardGap * CGFloat(row.tiles.count - 1)) / CGFloat(row.tiles.count)
                HStack(spacing: cardGap) {
                    ForEach(row.tiles) { tile in
                        card(tile).frame(width: cardWidth, height: rowHeight)
                    }
                }
            }
        }
        .frame(width: width, height: height)
    }

    /// One row of right-column cards.
    private struct CardRow: Identifiable {
        let id: Int
        let tiles: [ApplicationsDashboardTile]
    }

    /// Chunks the right-column cards into rows of two. An odd count leads with a
    /// single full-width row (matching My Clutter's "one then a pair" shape).
    private func rows(of tiles: [ApplicationsDashboardTile]) -> [CardRow] {
        var rows: [CardRow] = []
        var remaining = tiles
        if remaining.count % 2 == 1 {
            rows.append(CardRow(id: 0, tiles: [remaining.removeFirst()]))
        }
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(2))
            remaining.removeFirst(chunk.count)
            rows.append(CardRow(id: rows.count, tiles: chunk))
        }
        return rows
    }

    /// Renders one ranked tile with its recommendation card, or a reassurance
    /// backfill.
    @ViewBuilder
    private func card(_ tile: ApplicationsDashboardTile) -> some View {
        switch tile {
        case .recommendation(let recommendation):
            let spec = spec(for: recommendation)
            ApplicationsDashboardCard(
                title: spec.title,
                detail: spec.detail,
                icon: spec.icon,
                primaryLabel: spec.primaryLabel,
                primaryAction: spec.primaryAction,
                secondaryLabel: spec.secondaryLabel,
                secondaryAction: spec.secondaryAction,
                identifier: spec.id,
                iconCache: iconCache
            )
        case .reassurance(let content):
            ReassuranceCard(content: content, accent: accent)
        }
    }

    // MARK: Copy

    private var installedCountText: String {
        let format = String(
            localized: "We've found %lld apps on your Mac.",
            comment: "Applications dashboard headline; %lld is the installed-app count."
        )
        return String.localizedStringWithFormat(format, Int64(result.installedCount))
    }

    private var updateLabel: String {
        String(localized: "Update", comment: "Applications Updates card action that opens the Updater pane.")
    }

    private var installationFilesTitle: String {
        if result.installationFilesCount == 0 {
            return String(
                localized: "No Installation Files",
                comment: "Applications Installation Files card title when none are found."
            )
        }
        let format = String(
            localized: "%@ of Installation Files Found",
            comment: "Applications Installation Files card title; %@ is the reclaimable size."
        )
        return String.localizedStringWithFormat(format, smartScanByteFormatter.string(fromByteCount: result.installationFilesTotalBytes))
    }

    private var installationFilesDetail: String {
        if result.installationFilesCount == 0 {
            return String(
                localized: "No leftover disk images or installer packages in your Downloads or Desktop.",
                comment: "Applications Installation Files card detail when none are found."
            )
        }
        return String(
            localized: "DMGs and installers you no longer need.",
            comment: "Applications Installation Files card detail when some are found."
        )
    }

    private var unusedTitle: String {
        if result.unusedAppsCount == 0 {
            return String(
                localized: "No Unused Applications",
                comment: "Applications Unused card title when none are found."
            )
        }
        let format = String(
            localized: "%lld Unused Applications Found",
            comment: "Applications Unused card title; %lld is the unused-app count."
        )
        return String.localizedStringWithFormat(format, Int64(result.unusedAppsCount))
    }

    private var unusedDetail: String {
        if result.unusedAppsCount == 0 {
            return String(
                localized: "Every app has been opened recently.",
                comment: "Applications Unused card detail when none are found."
            )
        }
        let bytes = result.unusedAppsTotalBytes
        if bytes > 0 {
            let format = String(
                localized: "You may not need these apps, but they use %@ of space in total.",
                comment: "Applications Unused card detail; %@ is the total on-disk size of the unused apps."
            )
            return String.localizedStringWithFormat(format, smartScanByteFormatter.string(fromByteCount: bytes))
        }
        return String(
            localized: "You may not need these apps. Remove the ones you no longer use.",
            comment: "Applications Unused card detail shown when the total size could not be measured."
        )
    }

    private var updatesTitle: String {
        if result.updatesCount == 0 {
            return String(
                localized: "No Updates Available",
                comment: "Applications Updates card title when none are found."
            )
        }
        let format = String(
            localized: "%lld Updates Available",
            comment: "Applications Updates card title; %lld is the available-update count."
        )
        return String.localizedStringWithFormat(format, Int64(result.updatesCount))
    }

    private var updatesDetail: String {
        if result.updatesCount == 0 {
            return String(
                localized: "Every app is up to date.",
                comment: "Applications Updates card detail when none are found."
            )
        }
        return String(
            localized: "These apps have newer versions available. Update them to get the latest fixes.",
            comment: "Applications Updates card detail when some are found."
        )
    }

    private var leftoversTitle: String {
        if result.leftoversCount == 0 {
            return String(
                localized: "No App Leftovers",
                comment: "Applications Leftovers card title when none are found."
            )
        }
        let format = String(
            localized: "%@ of App Leftovers Found",
            comment: "Applications Leftovers card title; %@ is the reclaimable size."
        )
        return String.localizedStringWithFormat(format, smartScanByteFormatter.string(fromByteCount: result.leftoversTotalBytes))
    }

    private var leftoversDetail: String {
        if result.leftoversCount == 0 {
            return String(
                localized: "No support files from uninstalled apps were found.",
                comment: "Applications Leftovers card detail when none are found."
            )
        }
        return String(
            localized: "Bits left behind by apps you've uninstalled.",
            comment: "Applications Leftovers card detail when some are found."
        )
    }

    private var unsupportedTitle: String {
        if result.unsupportedAppsCount == 0 {
            return String(
                localized: "No Unsupported Applications",
                comment: "Applications Unsupported card title when none are found."
            )
        }
        let format = String(
            localized: "%lld Unsupported Applications Found",
            comment: "Applications Unsupported card title; %lld is the unsupported-app count."
        )
        return String.localizedStringWithFormat(format, Int64(result.unsupportedAppsCount))
    }

    private var unsupportedDetail: String {
        if result.unsupportedAppsCount == 0 {
            return String(
                localized: "Every installed app can run on this version of macOS.",
                comment: "Applications Unsupported card detail when none are found."
            )
        }
        return String(
            localized: "These apps won't run on this version of macOS — their code is built only for older architectures.",
            comment: "Applications Unsupported card detail when some are found."
        )
    }
}

// MARK: - Dashboard card (Applications)

/// How an Applications dashboard card illustrates its finding: a generated
/// raster tile (App Leftovers / installer DMG), a tinted SF Symbol, or a
/// cluster of the real app icons (the Unused card).
enum ApplicationsCardIcon {
    case asset(String)
    case symbol(String)
    case appIcons([URL])
}

/// A single Applications dashboard card in the reference layout: a title and
/// detail at the top with a top-right illustration, and a bottom action row.
/// The Unused card additionally shows a cluster of real app icons at the
/// bottom-left; the App Leftovers card shows a glass Review capsule plus a
/// white Remove capsule.
struct ApplicationsDashboardCard: View {
    let title: String
    let detail: String
    let icon: ApplicationsCardIcon
    let primaryLabel: String
    let primaryAction: () -> Void
    let secondaryLabel: String?
    let secondaryAction: (() -> Void)?
    let identifier: String
    var iconCache: AppIconCache

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                topRightIcon.frame(width: 52, height: 52)
            }
            // The Unused card fills its body with a centred cluster of the real
            // app icons; the others just push the action row to the bottom.
            if case .appIcons(let urls) = icon, !urls.isEmpty {
                Spacer(minLength: 12)
                appIconCluster(urls).frame(maxWidth: .infinity)
                Spacer(minLength: 12)
            } else {
                Spacer(minLength: 8)
            }
            HStack(spacing: 10) {
                Spacer()
                if let secondaryLabel, let secondaryAction {
                    Button(secondaryLabel, action: secondaryAction)
                        .buttonStyle(.vaderGlass)
                        .accessibilityIdentifier(identifier + ".secondary")
                }
                Button(primaryLabel, action: primaryAction)
                    .buttonStyle(.vaderWhite)
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaderTileGlass()
    }

    @ViewBuilder
    private var topRightIcon: some View {
        switch icon {
        case .asset(let name):
            Image(name).resizable().aspectRatio(contentMode: .fit)
        case .symbol(let name):
            Image(systemName: name)
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
                .padding(4)
        case .appIcons:
            // The Unused card illustrates with the icon cluster at the bottom.
            EmptyView()
        }
    }

    /// Overlapping real app icons for the Unused card, centred to fill the tall
    /// card body.
    private func appIconCluster(_ urls: [URL]) -> some View {
        HStack(spacing: -16) {
            ForEach(urls, id: \.self) { url in
                Image(nsImage: iconCache.icon(for: url))
                    .resizable()
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
        }
    }
}

// MARK: - Progress

/// Centered spinner shown while the Applications scan runs.
struct ApplicationsProgressState: View {
    var body: some View {
        VStack(spacing: 28) {
            ScanProgressIndicator()
            // The shared status view, so this loader's type matches every
            // other section's scan screen.
            ScanningStatusView(phrases: [String(
                localized: "Scanning your applications…",
                comment: "Progress label shown while the Applications scan runs."
            )])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.loading")
    }
}

// MARK: - Failed

/// Error state for a failed Applications scan, with a retry that re-runs it.
struct ApplicationsFailedState: View {
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(String(
                localized: "Couldn't scan your applications",
                comment: "Title shown on the Applications scan failure screen."
            ))
            .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("applications.errorMessage")
            Button(String(
                localized: "Try Again",
                comment: "Retry button on the Applications scan failure screen."
            ), action: onTryAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("applications.tryAgain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
