// ApplicationsDashboardSubviews.swift
// Post-scan dashboard for the Applications section — the "N apps found" header and recommendation cards on the shared section dashboard, and the progress / failed states.

import SwiftUI
import VaderCleanerCore

// MARK: - Dashboard

/// The Applications landing surface after a scan: the shared
/// `SectionDashboard` with the installed-app count, a "Manage My Applications"
/// action, and the ranked recommendation cards.
struct ApplicationsDashboardView: View {
    let result: ApplicationsScanResult
    var iconCache: AppIconCache
    /// Whether a removal is still moving files to the Trash, which holds off
    /// Start Over.
    let isRemoving: Bool
    let onOpenManage: () -> Void
    let onOpenInstallationFiles: () -> Void
    let onOpenUnsupported: () -> Void
    let onOpenUnused: () -> Void
    let onOpenUpdates: () -> Void
    let onOpenLeftovers: () -> Void
    /// One-click removal for the App Leftovers card's Remove button — selects
    /// every leftover group and moves it to the Trash.
    let onRemoveLeftovers: () -> Void
    /// Discards the results and returns to the section intro.
    let onStartOver: () -> Void

    var body: some View {
        SectionDashboard(
            section: .applications,
            headline: installedCountText,
            subheadline: String(
                localized: "Use quick recommendations or manage them by hand.",
                comment: "Applications dashboard subheadline beneath the installed-app count."
            ),
            headlineIdentifier: "applications.installedCount",
            headerAction: DashboardHeaderAction(
                title: String(
                    localized: "Manage My Applications",
                    comment: "Button that opens the full installed-apps management (uninstaller) list."
                ),
                identifier: "applications.manageMyApplications",
                action: onOpenManage
            ),
            startOver: DashboardStartOver(
                identifier: "applications.startOver",
                isDisabled: isRemoving,
                action: onStartOver
            ),
            identifier: "applications.dashboard"
        ) {
            DashboardGrid(tiles: tiles) { tile, role in
                card(tile, role: role)
            }
        }
        .task(id: result.unusedApps.map(\.id)) {
            // Preload the unused apps' icons for the Unused card's icon cluster.
            // Their on-disk sizes are already summed by the scan, so the detail
            // line's total is available on first paint.
            let urls = result.unusedApps.map { $0.app.bundleURL }
            await iconCache.preloadIcons(for: urls)
        }
    }

    /// One dashboard card's content, built as data so `card(_:role:)` renders
    /// every recommendation the same way.
    private struct CardSpec {
        let title: String
        let detail: String
        let icon: ApplicationsCardIcon
        let actions: [DashboardCardAction]
    }

    private var reviewLabel: String {
        String(localized: "Review", comment: "Applications card action that opens a review list.")
    }

    private var removeLabel: String {
        String(localized: "Remove", comment: "Applications card action that removes the finding directly.")
    }

    /// A lone Review on a card; its identifier is the card's, which the UI
    /// tests target.
    private func review(_ identifier: String, _ action: @escaping () -> Void) -> DashboardCardAction {
        DashboardCardAction(title: reviewLabel, prominence: .secondary, identifier: identifier, action: action)
    }

    private func spec(for recommendation: ApplicationsScanResult.Recommendation) -> CardSpec {
        switch recommendation {
        case .unsupported:
            return CardSpec(title: unsupportedTitle, detail: unsupportedDetail,
                            icon: .symbol("exclamationmark.triangle.fill"),
                            actions: [review("applications.card.unsupported", onOpenUnsupported)])
        case .unused:
            return CardSpec(title: unusedTitle, detail: unusedDetail,
                            icon: .appIcons(Array(result.unusedApps.prefix(3).map { $0.app.bundleURL })),
                            actions: [review("applications.card.unused", onOpenUnused)])
        case .updates:
            return CardSpec(title: updatesTitle, detail: updatesDetail,
                            icon: .symbol("arrow.down"),
                            actions: [review("applications.card.updates", onOpenUpdates)])
        case .leftovers:
            return CardSpec(title: leftoversTitle, detail: leftoversDetail,
                            icon: .symbol("puzzlepiece.fill"),
                            actions: [
                                review("applications.card.leftovers.secondary", onOpenLeftovers),
                                DashboardCardAction(title: removeLabel, prominence: .primary,
                                                    identifier: "applications.card.leftovers",
                                                    action: onRemoveLeftovers),
                            ])
        case .installationFiles:
            return CardSpec(title: installationFilesTitle, detail: installationFilesDetail,
                            icon: .symbol("externaldrive.fill"),
                            actions: [review("applications.card.installationFiles", onOpenInstallationFiles)])
        }
    }

    /// The ranked 2–4 cards this scan warrants, most actionable first.
    private var tiles: [ApplicationsDashboardTile] {
        result.recommendedTiles()
    }

    /// Renders one ranked tile with its recommendation card, or a reassurance
    /// backfill.
    @ViewBuilder
    private func card(_ tile: ApplicationsDashboardTile, role: DashboardTileRole) -> some View {
        switch tile {
        case .recommendation(let recommendation):
            let spec = spec(for: recommendation)
            DashboardCard(title: spec.title, detail: spec.detail, role: role, actions: spec.actions) {
                icon(spec.icon, isIllustration: false)
            } illustration: {
                icon(spec.icon, isIllustration: true)
            }
        case .reassurance(let content):
            DashboardReassuranceCard(content: content, role: role)
        }
    }

    @ViewBuilder
    private func icon(_ icon: ApplicationsCardIcon, isIllustration: Bool) -> some View {
        switch icon {
        case .symbol(let name):
            DashboardOrb(
                symbol: name,
                size: isIllustration ? DashboardOrb.illustrationSize : DashboardOrb.accessorySize
            )
        case .appIcons(let urls):
            appIconCluster(urls, iconSize: isIllustration ? 64 : 40)
        }
    }

    /// Overlapping real app icons for the Unused card.
    private func appIconCluster(_ urls: [URL], iconSize: CGFloat) -> some View {
        HStack(spacing: -iconSize / 4) {
            ForEach(urls, id: \.self) { url in
                Image(nsImage: iconCache.icon(for: url))
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
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
        return String.localizedStringWithFormat(format, formattedFileBytes(result.installationFilesTotalBytes))
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
            return String.localizedStringWithFormat(format, formattedFileBytes(bytes))
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
        return String.localizedStringWithFormat(format, formattedFileBytes(result.leftoversTotalBytes))
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
            localized: "These apps won't run on this version of macOS — their code isn't built for this Mac's processor.",
            comment: "Applications Unsupported card detail when some are found."
        )
    }
}

// MARK: - Card icon (Applications)

/// How an Applications dashboard card illustrates its finding: an orb with the
/// category's symbol, or a cluster of the real app icons (the Unused card).
enum ApplicationsCardIcon {
    case symbol(String)
    case appIcons([URL])
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
