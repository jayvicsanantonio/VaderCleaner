// SystemJunkDashboardSubviews.swift
// Category dashboard, tiles, and per-file review screens for the System Junk section — mirrors the Large & Old Files dashboard so the two sections share one look.

import SwiftUI
import AppKit
import VaderCleanerCore

// MARK: - Formatting

enum SystemJunkFormatting {
    /// Finder-matching file-style byte string, formatted through the shared
    /// helper so every surface reports sizes identically.
    static func formattedBytes(_ bytes: Int64) -> String {
        formattedFileBytes(bytes)
    }
}

// MARK: - Dashboard tile

/// One card on the Cleanup dashboard: either a junk group's card or an "all
/// good" reassurance card used to backfill the grid to its minimum count when a
/// scan finds fewer than two groups.
enum CleanupDashboardTile: Identifiable {
    case group(CleanupGroupTile)
    case reassurance(ReassuranceContent)

    var id: String {
        switch self {
        case .group(let tile):          return tile.id
        case .reassurance(let content): return "reassurance.\(content.id)"
        }
    }

    /// The 2–4 cards the Cleanup dashboard shows for a scan: the junk groups
    /// with the most reclaimable space lead (capped at four), backfilled with
    /// reassurance cards when a scan finds fewer than two groups.
    static func recommended(from result: ScanResult) -> [CleanupDashboardTile] {
        let real = CleanupGroupTile.tiles(from: result).map { tile in
            RankedTile(payload: CleanupDashboardTile.group(tile),
                       urgency: .space,
                       reclaimableBytes: tile.totalBytes)
        }
        let reassurance = reassurancePool.map { content in
            RankedTile(payload: CleanupDashboardTile.reassurance(content),
                       urgency: .reassurance,
                       reclaimableBytes: 0)
        }
        return SectionRecommendationSelector.select(real: real, reassurance: reassurance)
    }

    /// Bytes the headline counts that no card shows, because the grid holds fewer
    /// cards than a scan can find groups. They stay reachable through Review All,
    /// and the caption this feeds says so.
    static func unshownBytes(totalBytes: Int64, tiles: [CleanupDashboardTile]) -> Int64 {
        let shown = tiles.reduce(Int64(0)) { sum, tile in
            if case .group(let group) = tile { return sum + group.totalBytes }
            return sum
        }
        return max(0, totalBytes - shown)
    }

    /// Ordered pool of "all good" cards, drawn from in order when a scan finds
    /// fewer than two junk groups so backfilling never repeats a card. Any card
    /// beside a real finding comes from the front of the pool, whatever that
    /// finding's size, so the front must not claim there's little junk: "almost
    /// no junk" read as nonsense next to a 200 GB Trash.
    static let reassurancePool: [ReassuranceContent] = [
        ReassuranceContent(
            id: "cleanup.checkBack",
            title: String(localized: "Check Back Later", comment: "Cleanup reassurance card title."),
            detail: String(
                localized: "Junk builds up as you use your Mac. Re-scan any time to keep it lean.",
                comment: "Cleanup reassurance card detail."
            ),
            icon: "clock.arrow.circlepath"
        ),
        ReassuranceContent(
            id: "cleanup.tidy",
            title: String(localized: "Your Mac Is Tidy", comment: "Cleanup reassurance card title."),
            detail: String(
                localized: "There's almost no junk to clear right now. Nicely kept.",
                comment: "Cleanup reassurance card detail."
            ),
            icon: "sparkles"
        ),
    ]
}

// MARK: - Dashboard

/// Post-scan landing surface for the Cleanup section: the shared
/// `SectionDashboard` with the total-junk headline, a "Review All Junk" action,
/// and a card per `CleanupGroup`, the group with the most reclaimable space
/// leading. Each card's Review drills into that group's files; the groups that
/// allow it also offer a direct Clean.
struct SystemJunkDashboardView: View {
    let totalBytes: Int64
    let tiles: [CleanupDashboardTile]
    /// Drills into one group's combined file list.
    let onReview: (CleanupGroup) -> Void
    /// Cleans an entire group directly (only the cards that allow it call this).
    let onClean: (CleanupGroup) -> Void
    /// Opens the complete, unfiltered junk file list across every group.
    let onReviewAll: () -> Void
    /// Discards the current scan and returns to the section intro.
    let onStartOver: () -> Void

    var body: some View {
        SectionDashboard(
            section: .systemJunk,
            headline: headline,
            subheadline: String(
                localized: "Clean a category directly, or review its files first.",
                comment: "Cleanup dashboard subheadline beneath the total-junk headline."
            ),
            headlineIdentifier: "system-junk.summary",
            headerAction: DashboardHeaderAction(
                title: String(
                    localized: "Review All Junk",
                    comment: "Button that opens the complete, unfiltered junk file list across every category."
                ),
                identifier: "system-junk.viewAll",
                action: onReviewAll
            ),
            // Keeps the `system-junk.rescan` identifier the UI tests already target.
            startOver: DashboardStartOver(identifier: "system-junk.rescan", action: onStartOver),
            identifier: "system-junk.dashboard"
        ) {
            unshownCaption
        } grid: {
            DashboardGrid(tiles: tiles) { tile, role in
                card(tile, role: role)
            }
        }
    }

    @ViewBuilder
    private var unshownCaption: some View {
        let unshown = CleanupDashboardTile.unshownBytes(totalBytes: totalBytes, tiles: tiles)
        if unshown > 0 {
            Text(String.localizedStringWithFormat(
                String(
                    localized: "Includes %@ not shown below. Review All Junk lists everything.",
                    comment: "Cleanup dashboard caption when a junk group has no card; %@ is the size of what the cards leave out."
                ),
                SystemJunkFormatting.formattedBytes(unshown)
            ))
            .font(.callout)
            .foregroundStyle(.white.opacity(0.75))
            .accessibilityIdentifier("system-junk.unshown")
        }
    }

    private var headline: String {
        let size = SystemJunkFormatting.formattedBytes(totalBytes)
        let format = String(
            localized: "There are %@ of junk files on your Mac.",
            comment: "Cleanup dashboard headline; %@ is the total reclaimable size."
        )
        return String.localizedStringWithFormat(format, size)
    }

    @ViewBuilder
    private func card(_ tile: CleanupDashboardTile, role: DashboardTileRole) -> some View {
        switch tile {
        case .group(let groupTile):
            let group = groupTile.group
            let identifierBase = "system-junk.card.\(group.rawValue)"
            DashboardCard(
                title: cardTitle(for: groupTile),
                detail: group.blurb,
                role: role,
                actions: actions(for: group, identifierBase: identifierBase)
            ) {
                DashboardBadge(asset: group.badgeAsset)
            } illustration: {
                DashboardBadge(asset: group.badgeAsset, size: DashboardOrb.illustrationSize)
            }
        case .reassurance(let content):
            DashboardReassuranceCard(content: content, role: role)
        }
    }

    private func actions(for group: CleanupGroup, identifierBase: String) -> [DashboardCardAction] {
        var actions = [DashboardCardAction(
            title: String(localized: "Review", comment: "Cleanup card action that opens the group's file list."),
            prominence: .secondary,
            identifier: "\(identifierBase).review",
            action: { onReview(group) }
        )]
        if group.allowsDirectClean {
            actions.append(DashboardCardAction(
                title: String(localized: "Clean", comment: "Cleanup card action that removes the whole group directly."),
                prominence: .primary,
                identifier: "\(identifierBase).clean",
                action: { onClean(group) }
            ))
        }
        return actions
    }

    /// "30.9 GB of System Junk Found" — the size-led title from the reference.
    private func cardTitle(for tile: CleanupGroupTile) -> String {
        let size = SystemJunkFormatting.formattedBytes(tile.totalBytes)
        let format = String(
            localized: "%1$@ of %2$@ Found",
            comment: "Cleanup card title; %1$@ is the reclaimable size, %2$@ the group name, e.g. \"30.9 GB of System Junk Found\"."
        )
        return String.localizedStringWithFormat(format, size, tile.group.title)
    }
}
