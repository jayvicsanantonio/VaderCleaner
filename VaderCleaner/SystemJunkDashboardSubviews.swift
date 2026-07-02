// SystemJunkDashboardSubviews.swift
// Category dashboard, tiles, and per-file review screens for the System Junk section — mirrors the Large & Old Files dashboard so the two sections share one look.

import SwiftUI
import AppKit

// MARK: - Formatting

enum SystemJunkFormatting {
    /// Shared file-size formatter for the dashboard tiles and card titles.
    /// Constructed once because `ByteCountFormatter` allocates measurable
    /// internal state per instance.
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
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

    /// Ordered pool of "all good" cards, drawn from in order when a scan finds
    /// fewer than two junk groups so backfilling never repeats a card.
    static let reassurancePool: [ReassuranceContent] = [
        ReassuranceContent(
            id: "cleanup.tidy",
            title: String(localized: "Your Mac Is Tidy", comment: "Cleanup reassurance card title."),
            detail: String(
                localized: "There's almost no junk to clear right now. Nicely kept.",
                comment: "Cleanup reassurance card detail."
            ),
            icon: "sparkles"
        ),
        ReassuranceContent(
            id: "cleanup.checkBack",
            title: String(localized: "Check Back Later", comment: "Cleanup reassurance card title."),
            detail: String(
                localized: "Junk builds up as you use your Mac. Re-scan any time to keep it lean.",
                comment: "Cleanup reassurance card detail."
            ),
            icon: "clock.arrow.circlepath"
        ),
    ]
}

// MARK: - Dashboard

/// Post-scan landing surface for the Cleanup section: a "Start Over" bar, the
/// total-junk headline, a "Review All Junk" action, and a bento grid of
/// `CleanupGroup` cards. The heaviest, most general bucket (System Junk) is a
/// tall hero in the left column; Trash Bins, Xcode Junk, and Document Versions
/// fill the right column (a wide card on top, the rest in rows of two). Each
/// card's Review drills into that group's files; the System Junk and Trash Bins
/// cards also offer a direct Clean.
struct SystemJunkDashboardView: View {
    let totalBytes: Int64
    let tiles: [CleanupDashboardTile]
    /// Section accent, used to tint any reassurance backfill cards.
    let accent: Color
    /// Drills into one group's combined file list.
    let onReview: (CleanupGroup) -> Void
    /// Cleans an entire group directly (only the cards that allow it call this).
    let onClean: (CleanupGroup) -> Void
    /// Opens the complete, unfiltered junk file list across every group.
    let onReviewAll: () -> Void
    /// Discards the current scan and returns to the section intro.
    let onStartOver: () -> Void

    /// Fixed width of the hero column so it keeps a stable shape while the right
    /// cards absorb the remaining width.
    private let heroColumnWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            startOverBar
            VStack(spacing: 20) {
                header
                cardLayout
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("system-junk.dashboard")
    }

    /// Top-left "Start Over" control, mirroring the Smart Scan dashboard's bar.
    /// Uses an explicit `HStack(Image, Text)` rather than `Label` so it surfaces
    /// reliably as a button in XCUITest. Keeps the `system-junk.rescan`
    /// identifier the UI tests already target.
    private var startOverBar: some View {
        HStack {
            Button(action: onStartOver) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(String(
                        localized: "Start Over",
                        comment: "Button on the Cleanup results screen that discards the scan and returns to the intro."
                    ))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("system-junk.rescan")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    /// The section hero, the white total-junk headline, and the "Review All
    /// Junk" action beneath — mirroring the Performance dashboard's hero, sized
    /// so the bento grid still has room below.
    private var header: some View {
        VStack(spacing: 14) {
            Image("systemJunk")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 140, maxHeight: 140)
                .accessibilityHidden(true)

            Text(headline)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .accessibilityIdentifier("system-junk.summary")

            Button(action: onReviewAll) {
                Text(String(
                    localized: "Review All Junk",
                    comment: "Button that opens the complete, unfiltered junk file list across every category."
                ))
                .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("system-junk.viewAll")
        }
    }

    private var headline: String {
        let size = SystemJunkFormatting.byteFormatter.string(fromByteCount: totalBytes)
        let format = String(
            localized: "There are %@ of junk files on your Mac.",
            comment: "Cleanup dashboard headline; %@ is the total reclaimable size."
        )
        return String.localizedStringWithFormat(format, size)
    }

    /// The bento grid: a hero on the left and the remaining cards in the right
    /// column (a wide card on top, the rest in rows of two). Lower card counts
    /// degrade gracefully so the pane never shows an orphaned hero beside empty
    /// space.
    @ViewBuilder
    private var cardLayout: some View {
        switch tiles.count {
        case 0:
            EmptyView()
        case 1:
            card(tiles[0], style: .hero)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            HStack(alignment: .top, spacing: 16) {
                card(tiles[0], style: .hero)
                    .frame(width: heroColumnWidth)
                    .frame(maxHeight: .infinity)
                rightColumn(Array(tiles.dropFirst()))
            }
        }
    }

    /// The non-hero cards: the first is a wide card spanning the column, the rest
    /// flow in rows of two beneath it. Grouped in a `GlassEffectContainer` so the
    /// adjacent glass surfaces sample each other and refract consistently.
    private func rightColumn(_ rest: [CleanupDashboardTile]) -> some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 16) {
                if let wide = rest.first {
                    card(wide, style: .wide)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(Array(rows(of: Array(rest.dropFirst())).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 16) {
                        ForEach(row) { tile in
                            card(tile, style: .compact)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Chunks the compact cards into rows of at most two so the lower grid reads
    /// as a balanced two-up arrangement.
    private func rows(of tiles: [CleanupDashboardTile]) -> [[CleanupDashboardTile]] {
        stride(from: 0, to: tiles.count, by: 2).map {
            Array(tiles[$0..<min($0 + 2, tiles.count)])
        }
    }

    @ViewBuilder
    private func card(_ tile: CleanupDashboardTile, style: CleanupCardStyle) -> some View {
        switch tile {
        case .group(let groupTile):
            CleanupCard(
                title: cardTitle(for: groupTile),
                blurb: groupTile.group.blurb,
                badgeAsset: groupTile.group.badgeAsset,
                style: style,
                showsClean: groupTile.group.allowsDirectClean,
                identifierBase: "system-junk.card.\(groupTile.group.rawValue)",
                onReview: { onReview(groupTile.group) },
                onClean: { onClean(groupTile.group) }
            )
        case .reassurance(let content):
            ReassuranceCard(content: content, accent: accent)
        }
    }

    /// "30.9 GB of System Junk Found" — the size-led title from the reference.
    private func cardTitle(for tile: CleanupGroupTile) -> String {
        let size = SystemJunkFormatting.byteFormatter.string(fromByteCount: tile.totalBytes)
        let format = String(
            localized: "%1$@ of %2$@ Found",
            comment: "Cleanup card title; %1$@ is the reclaimable size, %2$@ the group name, e.g. \"30.9 GB of System Junk Found\"."
        )
        return String.localizedStringWithFormat(format, size, tile.group.title)
    }
}

// MARK: - Cleanup card

/// How a `CleanupCard` lays itself out. `hero` is the tall lead card with a
/// large centered glyph; `wide` spans the right column with a top-right glyph;
/// `compact` is a small card with a top-right glyph and no description, matching
/// the reference's bottom-row cards.
enum CleanupCardStyle {
    case hero
    case wide
    case compact
}

/// One Cleanup dashboard card: a size-led title, an optional description, a
/// glossy 3D badge, and Review / Clean actions. Shares the glass surface and
/// corner radius of the app's other dashboard cards so the surfaces stay
/// consistent.
struct CleanupCard: View {
    let title: String
    let blurb: String
    /// Asset-catalog name of the glossy 3D badge artwork.
    let badgeAsset: String
    let style: CleanupCardStyle
    /// Whether to show the prominent Clean action beside Review.
    let showsClean: Bool
    /// Prefix for the card's button identifiers, e.g. `system-junk.card.trashBins`.
    let identifierBase: String
    let onReview: () -> Void
    let onClean: () -> Void

    private var isHero: Bool { style == .hero }
    /// Compact cards drop the description, matching the reference's small cards.
    private var showsBlurb: Bool { style != .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(title)
                    .font(isHero ? .title3.weight(.semibold) : .headline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !isHero {
                    badge(size: 56)
                }
            }

            if showsBlurb {
                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if isHero {
                HStack {
                    Spacer()
                    badge(size: 150)
                    Spacer()
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Spacer()
                Button(String(
                    localized: "Review",
                    comment: "Cleanup card action that opens the group's file list."
                ), action: onReview)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(identifierBase).review")

                if showsClean {
                    Button(String(
                        localized: "Clean",
                        comment: "Cleanup card action that removes the whole group directly."
                    ), action: onClean)
                    .buttonStyle(.vaderProminent)
                    .accessibilityIdentifier("\(identifierBase).clean")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: isHero ? 320 : 150, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    /// The glossy 3D badge artwork. The baked PNG carries its own soft drop
    /// shadow and fills ~80% of its frame, so the requested `size` is a little
    /// larger than the visible orb.
    private func badge(size: CGFloat) -> some View {
        Image(badgeAsset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
