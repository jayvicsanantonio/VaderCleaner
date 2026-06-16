// SystemJunkDashboardSubviews.swift
// Category dashboard, tiles, and per-file review screens for the System Junk section — mirrors the Large & Old Files dashboard so the two sections share one look.

import SwiftUI
import AppKit

// MARK: - Formatting

enum SystemJunkFormatting {
    /// Shared file-size formatter for the dashboard tiles, review header, rows,
    /// and footer. Constructed once because `ByteCountFormatter` allocates
    /// measurable internal state per instance.
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()

    /// Accessibility label for a review row's selection checkbox.
    static func selectionLabel(for file: ScannedFile) -> String {
        let format = String(
            localized: "Select %@",
            comment: "Accessibility label for selecting a file in the System Junk review list."
        )
        return String.localizedStringWithFormat(format, file.url.lastPathComponent)
    }
}

// MARK: - Tile presentation

/// View-layer presentation metadata for the junk categories — the SF Symbol and
/// one-line descriptor each tile shows. Kept here rather than on the persisted
/// `ScanCategory` domain enum so the stable codable cases stay free of UI copy.
/// `largeFile` / `oldFile` never appear in a System Junk scan (they belong to
/// the Large & Old Files section), so they get a neutral fallback.
extension ScanCategory {
    var systemJunkIcon: String {
        switch self {
        case .systemCache:     return "internaldrive"
        case .userCache:       return "person.crop.circle"
        case .systemLogs:      return "doc.text.magnifyingglass"
        case .userLogs:        return "doc.text"
        case .languageFiles:   return "globe"
        case .mailAttachments: return "paperclip"
        case .iosBackups:      return "iphone"
        case .trash:           return "trash"
        case .largeFile, .oldFile: return "doc"
        }
    }

    var systemJunkBlurb: String {
        switch self {
        case .systemCache:
            return String(localized: "Rebuildable caches written by macOS.",
                          comment: "System Junk System Caches tile detail line.")
        case .userCache:
            return String(localized: "Temporary files your apps can recreate.",
                          comment: "System Junk User Caches tile detail line.")
        case .systemLogs:
            return String(localized: "Diagnostic logs written by the system.",
                          comment: "System Junk System Logs tile detail line.")
        case .userLogs:
            return String(localized: "Diagnostic logs written by your apps.",
                          comment: "System Junk User Logs tile detail line.")
        case .languageFiles:
            return String(localized: "Unused localizations bundled with apps.",
                          comment: "System Junk Language Files tile detail line.")
        case .mailAttachments:
            return String(localized: "Downloaded copies of Mail attachments.",
                          comment: "System Junk Mail Attachments tile detail line.")
        case .iosBackups:
            return String(localized: "Old iPhone and iPad backups.",
                          comment: "System Junk iOS Backups tile detail line.")
        case .trash:
            return String(localized: "Items already in the Trash.",
                          comment: "System Junk Trash tile detail line.")
        case .largeFile, .oldFile:
            return String(localized: "Removable files found on disk.",
                          comment: "System Junk fallback tile detail line.")
        }
    }
}

/// One dashboard tile: a category and the files that fall under it. The size is
/// taken from the scan result's precomputed `sizeByCategory` so the tile never
/// re-sums the files on construction.
struct SystemJunkTile: Identifiable, Equatable {
    let category: ScanCategory
    let files: [ScannedFile]
    let count: Int
    let totalBytes: Int64

    var id: String { category.rawValue }

    init(category: ScanCategory, files: [ScannedFile], totalBytes: Int64) {
        self.category = category
        self.files = files
        self.count = files.count
        self.totalBytes = totalBytes
    }

    /// One tile per category present in `result`, heaviest first so the caller
    /// can promote the first to a hero card. Categories with no findings are
    /// absent from `itemsByCategory`, so they never produce a tile.
    static func tiles(from result: ScanResult) -> [SystemJunkTile] {
        ScanCategory.allCases
            .compactMap { category in
                guard let files = result.itemsByCategory[category] else { return nil }
                return SystemJunkTile(
                    category: category,
                    files: files,
                    totalBytes: result.sizeByCategory[category] ?? 0
                )
            }
            .sorted { $0.totalBytes > $1.totalBytes }
    }
}

// MARK: - Dashboard

/// Post-scan landing surface for System Junk: a summary header and a grid of
/// category tiles. Modelled on `LargeOldFilesDashboardView` — the whole surface
/// fills the detail pane without a scroll view: the heaviest category is a tall
/// hero in a fixed-width left column, and the remaining tiles divide the right
/// column's height into equal rows. Each tile's Review button drills into that
/// category's file list.
struct SystemJunkDashboardView: View {
    let totalBytes: Int64
    let itemCount: Int
    let tiles: [SystemJunkTile]
    let onReview: (ScanCategory) -> Void
    /// Opens the complete, unfiltered file list — the analog of the Large & Old
    /// Files section's "View All Files".
    let onViewAll: () -> Void
    let onRescan: () -> Void

    /// Fixed width of the hero column so it keeps a stable shape while the right
    /// tiles absorb the remaining width — mirrors `LargeOldFilesDashboardView`.
    private let leftColumnWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 16) {
            header
            cardLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("system-junk.dashboard")
    }

    /// Centred size headline with the two primary actions beneath it, echoing
    /// the Large & Old Files dashboard header.
    private var header: some View {
        VStack(spacing: 12) {
            Text(headline)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("system-junk.summary")
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(String(
                    localized: "View All Files",
                    comment: "Button that opens the complete, unfiltered System Junk file list."
                )) {
                    onViewAll()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("system-junk.viewAll")

                Button(String(
                    localized: "Re-scan",
                    comment: "Button that re-runs the System Junk scan from the dashboard."
                )) {
                    onRescan()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("system-junk.rescan")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        let size = SystemJunkFormatting.byteFormatter.string(fromByteCount: totalBytes)
        let format = String(
            localized: "We've found %@ of removable junk on your Mac.",
            comment: "System Junk dashboard headline; %@ is the total reclaimable size."
        )
        return String.localizedStringWithFormat(format, size)
    }

    private var detail: String {
        let format = String(
            localized: "%1$lld items across %2$lld categories.",
            comment: "System Junk dashboard detail; %1$lld is the item count, %2$lld the category count."
        )
        return String.localizedStringWithFormat(format, Int64(itemCount), Int64(tiles.count))
    }

    /// The Large & Old Files layout: a tall hero in the left column with a
    /// shorter secondary card tucked beneath it, and the remaining tiles
    /// dividing the right column into equal-height rows of two. Lower tile
    /// counts degrade gracefully so the pane never shows an orphaned hero beside
    /// empty space.
    @ViewBuilder
    private var cardLayout: some View {
        switch tiles.count {
        case 0:
            EmptyView()
        case 1:
            card(tiles[0], isHero: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case 2:
            HStack(alignment: .top, spacing: 16) {
                card(tiles[0], isHero: true)
                    .frame(width: leftColumnWidth)
                    .frame(maxHeight: .infinity)
                card(tiles[1], isHero: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            HStack(alignment: .top, spacing: 16) {
                leftColumn
                rightGrid(gridTiles)
            }
        }
    }

    /// The hero plus the compact secondary card. The hero stretches to fill the
    /// column height while the secondary keeps its natural (shorter) height, so
    /// the two read as clearly different sizes.
    private var leftColumn: some View {
        VStack(spacing: 16) {
            card(tiles[0], isHero: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let secondaryTile {
                card(secondaryTile, isHero: false)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: leftColumnWidth)
    }

    /// The non-hero tiles, excluding the one promoted to the compact left card.
    private var nonHeroTiles: [SystemJunkTile] { Array(tiles.dropFirst()) }

    /// The smallest non-hero category by reclaimable size becomes the compact
    /// card under the hero — a small tile for a small bucket.
    private var secondaryTile: SystemJunkTile? {
        nonHeroTiles.min { $0.totalBytes < $1.totalBytes }
    }

    /// What flows through the right grid: every non-hero tile except the one
    /// shown as the compact left card.
    private var gridTiles: [SystemJunkTile] {
        nonHeroTiles.filter { $0.id != secondaryTile?.id }
    }

    /// The non-hero tiles in equal-height rows of two. Grouped in a
    /// `GlassEffectContainer` so adjacent glass cards sample each other and
    /// refract consistently, exactly as the Large & Old Files grid does.
    private func rightGrid(_ gridTiles: [SystemJunkTile]) -> some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 16) {
                ForEach(Array(rows(of: gridTiles).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 16) {
                        ForEach(row) { tile in
                            card(tile, isHero: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Chunks the grid tiles into rows of at most two so the right column reads
    /// as a two-up grid that fills the height.
    private func rows(of gridTiles: [SystemJunkTile]) -> [[SystemJunkTile]] {
        stride(from: 0, to: gridTiles.count, by: 2).map {
            Array(gridTiles[$0..<min($0 + 2, gridTiles.count)])
        }
    }

    private func card(_ tile: SystemJunkTile, isHero: Bool) -> some View {
        ApplicationsCard(
            title: tile.category.displayName,
            metric: SystemJunkFormatting.byteFormatter.string(fromByteCount: tile.totalBytes),
            detail: cardDetail(for: tile),
            icon: tile.category.systemJunkIcon,
            actionLabel: String(
                localized: "Review",
                comment: "System Junk tile action that opens the category's file list."
            ),
            identifier: "system-junk.card.\(tile.category.rawValue)",
            isHero: isHero,
            action: { onReview(tile.category) }
        )
    }

    private func cardDetail(for tile: SystemJunkTile) -> String {
        let count = "\(tile.count) item\(tile.count == 1 ? "" : "s")"
        return "\(count) · \(tile.category.systemJunkBlurb)"
    }
}

// MARK: - Review

/// A drill-down's file list: a count header, the per-file selectable list, and a
/// footer with Re-scan and Clean. Mirrors `LargeOldFilesResultsContent` — the
/// rendered rows are capped so a category with very many files doesn't freeze the
/// drill-down building identity for the whole collection up front.
struct SystemJunkReviewContent: View {
    let files: [ScannedFile]
    /// Summed size of every file in this drill-down, for the header.
    let totalBytes: Int64
    let totalSelectedSize: Int64
    let canClean: Bool
    var fileIconCache: FileIconCache
    let isSelected: (ScannedFile) -> Bool
    let onToggleSelection: (ScannedFile) -> Void
    let onRescan: () -> Void
    let onClean: () -> Void

    /// Most rows we render at once. The selection set still spans the full file
    /// list; only the rendered rows are bounded.
    static let displayRowLimit = 1_000

    var body: some View {
        let shown = files.count > Self.displayRowLimit
            ? Array(files.prefix(Self.displayRowLimit))
            : files

        VStack(spacing: 0) {
            SystemJunkReviewHeader(fileCount: files.count, totalBytes: totalBytes)
            Divider()
            if files.count > shown.count {
                truncationNote(showing: shown.count, total: files.count)
                Divider()
            }
            SystemJunkReviewList(
                files: shown,
                fileIconCache: fileIconCache,
                isSelected: isSelected,
                onToggleSelection: onToggleSelection
            )
            Divider()
            SystemJunkReviewFooter(
                totalSelectedSize: totalSelectedSize,
                canClean: canClean,
                onRescan: onRescan,
                onClean: onClean
            )
        }
        // Key the preload on the bounded slice so it stays cheap.
        .task(id: shown) {
            await fileIconCache.preloadIcons(for: shown.map(\.url))
        }
    }

    /// Inline note explaining the list is showing only the top slice of a very
    /// large result set.
    private func truncationNote(showing: Int, total: Int) -> some View {
        let format = String(
            localized: "Showing the top %1$lld of %2$lld files. Clean these and re-scan to see more.",
            comment: "Note shown when the System Junk review list is capped; %1$lld is the shown count, %2$lld the total."
        )
        return HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(String.localizedStringWithFormat(format, Int64(showing), Int64(total)))
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Header bar above the review list: a file-count headline with the reclaimable
/// total beneath it.
struct SystemJunkReviewHeader: View {
    let fileCount: Int
    let totalBytes: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("system-junk.reviewSummary")
                Text(SystemJunkFormatting.byteFormatter.string(fromByteCount: totalBytes) + " total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The review files as a `List` of glass rows — the same pattern every other
/// section uses. `scrollContentBackground` is hidden so the branded gradient
/// shows through.
struct SystemJunkReviewList: View {
    let files: [ScannedFile]
    var fileIconCache: FileIconCache
    let isSelected: (ScannedFile) -> Bool
    let onToggleSelection: (ScannedFile) -> Void

    var body: some View {
        List {
            ForEach(files) { file in
                SystemJunkReviewRow(
                    file: file,
                    fileIconCache: fileIconCache,
                    isSelected: isSelected(file),
                    onToggleSelection: { onToggleSelection(file) }
                )
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("system-junk.table")
    }
}

/// One file in the review list: selection checkbox, type icon, name, the
/// containing folder, and the size as a bold trailing metric.
struct SystemJunkReviewRow: View {
    let file: ScannedFile
    var fileIconCache: FileIconCache
    let isSelected: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelection() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(Text(SystemJunkFormatting.selectionLabel(for: file)))
            .accessibilityIdentifier("system-junk.row.\(file.url.path).checkbox")

            Image(nsImage: fileIconCache.cachedIcon(for: file.url))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.url.path)
            }

            Spacer()

            Text(SystemJunkFormatting.byteFormatter.string(fromByteCount: file.size))
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityIdentifier("system-junk.row.\(file.url.path)")
    }
}

/// Pinned footer with the running selection total, a Re-scan, and the prominent
/// Clean action. Clean removes the whole current selection (which may span
/// categories), mirroring the Large & Old Files "Delete Selected" footer.
struct SystemJunkReviewFooter: View {
    let totalSelectedSize: Int64
    let canClean: Bool
    let onRescan: () -> Void
    let onClean: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SystemJunkFormatting.byteFormatter.string(fromByteCount: totalSelectedSize))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("system-junk.totalSelected")
            }
            Spacer()
            Button("Re-scan", action: onRescan)
                .accessibilityIdentifier("system-junk.rescan")
            Button("Clean", action: onClean)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.vaderProminent)
                .disabled(!canClean)
                .accessibilityIdentifier("system-junk.clean")
        }
        .padding(16)
    }
}
