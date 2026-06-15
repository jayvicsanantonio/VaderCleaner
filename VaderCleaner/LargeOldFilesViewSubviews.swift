// LargeOldFilesViewSubviews.swift
// Dedicated subviews for LargeOldFilesView state screens, table, rows, and footer.

import SwiftUI
import AppKit

enum LargeOldFilesFormatting {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func accessDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    static func selectionLabel(for file: ScannedFile) -> String {
        let format = String(
            localized: "Select %@",
            comment: "Accessibility label for selecting a file in the Large & Old Files table."
        )
        return String.localizedStringWithFormat(format, file.url.lastPathComponent)
    }
}

enum LargeOldFilesActions {
    static func showInFinder(_ file: ScannedFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }
}

/// Pure strings for the results header above the file list: a headline file
/// count and a supporting detail line. Kept free of any view so the phrasing
/// is unit-testable without rendering.
enum LargeOldFilesSummary {
    /// Headline metric — the bare, pluralized file count, e.g. "142 files".
    static func headline(count: Int) -> String {
        "\(count) file\(count == 1 ? "" : "s")"
    }

    /// Full-sentence headline for the dashboard, echoing the Applications
    /// section's "We've found N apps on your Mac." phrasing.
    static func foundSentence(count: Int) -> String {
        let format = String(
            localized: "We've found %lld large or old files on your Mac.",
            comment: "Large & Old Files dashboard headline; %lld is the file count."
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }

    /// Supporting detail — the count of age-qualified files and the total
    /// reclaimable size, separated by a middle dot. The old-file clause is
    /// dropped when nothing qualified so the line never reads "0 older than
    /// six months". Takes precomputed aggregates so the header never re-scans a
    /// huge result set on render.
    static func detail(oldCount: Int, totalBytes: Int64) -> String {
        let totalClause = LargeOldFilesFormatting.byteFormatter.string(fromByteCount: totalBytes) + " total"
        guard oldCount > 0 else { return totalClause }
        return "\(oldCount) older than 6 months · \(totalClause)"
    }

    // Convenience overloads that derive the aggregates from a file array — used
    // by tests and any caller that hasn't already summarized the set.

    static func headline(for files: [ScannedFile]) -> String {
        headline(count: files.count)
    }

    static func foundSentence(for files: [ScannedFile]) -> String {
        foundSentence(count: files.count)
    }

    static func detail(for files: [ScannedFile]) -> String {
        var totalBytes: Int64 = 0
        var oldCount = 0
        for file in files {
            totalBytes += file.size
            if file.category == .oldFile { oldCount += 1 }
        }
        return detail(oldCount: oldCount, totalBytes: totalBytes)
    }
}

struct LargeOldFilesProgressState: View {
    let label: String
    let identifier: String
    /// Optional live progress line (e.g. "Scanned 12,431 items…") shown beneath
    /// the label so the user can see an open-ended scan advancing.
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("\(identifier).count")
            }
        }
        .padding()
        .accessibilityIdentifier(identifier)
    }
}

struct LargeOldFilesResultsContent: View {
    let files: [ScannedFile]
    /// Precomputed aggregates for the header, so it never re-scans `files`
    /// (which can be hundreds of thousands of entries) on render.
    let oldCount: Int
    let totalBytes: Int64
    @Binding var sortOrder: LargeOldFilesViewModel.SortOrder
    let totalSelectedSize: Int64
    let canDelete: Bool
    var fileIconCache: FileIconCache
    let isSelected: (ScannedFile) -> Bool
    let onToggleSelection: (ScannedFile) -> Void
    let onRescan: () -> Void
    let onDeleteSelected: () -> Void
    let onShowInFinder: (ScannedFile) -> Void
    let onDeleteFile: (ScannedFile) -> Void
    let onAddToExclusions: (ScannedFile) -> Void

    /// Most rows we render at once. A category like "Old Files" can hold
    /// hundreds of thousands of entries, and a SwiftUI `List`/`ForEach` builds
    /// identity for the whole collection up front — rendering all of them froze
    /// the drill-down for seconds. The list is already sorted (size-descending
    /// by default), so the capped slice is the meaningful, actionable top of the
    /// list; the tail is reached by deleting these and re-scanning.
    static let displayRowLimit = 1_000

    var body: some View {
        // Cap the rendered rows. `files` stays the full set for the header's
        // true totals; only the list is bounded.
        let shown = files.count > Self.displayRowLimit
            ? Array(files.prefix(Self.displayRowLimit))
            : files

        VStack(spacing: 0) {
            LargeOldFilesResultsHeader(
                fileCount: files.count,
                oldCount: oldCount,
                totalBytes: totalBytes,
                sortOrder: $sortOrder
            )
            Divider()
            if files.count > shown.count {
                truncationNote(showing: shown.count, total: files.count)
                Divider()
            }
            LargeOldFilesList(
                files: shown,
                fileIconCache: fileIconCache,
                isSelected: isSelected,
                onToggleSelection: onToggleSelection,
                onShowInFinder: onShowInFinder,
                onDeleteFile: onDeleteFile,
                onAddToExclusions: onAddToExclusions
            )
            Divider()
            LargeOldFilesFooter(
                totalSelectedSize: totalSelectedSize,
                canDelete: canDelete,
                onRescan: onRescan,
                onDeleteSelected: onDeleteSelected
            )
        }
        // Key the preload on the bounded slice (≤ `displayRowLimit`) so it stays
        // cheap and doesn't compare the full hundreds-of-thousands array.
        .task(id: shown) {
            await fileIconCache.preloadIcons(for: shown.map(\.url))
        }
    }

    /// Inline note explaining the list is showing only the top slice of a very
    /// large result set.
    private func truncationNote(showing: Int, total: Int) -> some View {
        let format = String(
            localized: "Showing the top %lld of %lld files. Clear these and re-scan to see more.",
            comment: "Note shown when the Large & Old Files list is capped; the first %lld is the shown count, the second the total."
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

/// Post-scan landing surface for Large & Old Files: a summary header and a grid
/// of category tiles. Modelled on the Health Monitor dashboard — the whole
/// surface fills the detail pane without a scroll view: the heaviest category is
/// a tall hero in a fixed-width left column, and the remaining tiles divide the
/// right column's height into equal rows so the grid never overflows. Each
/// tile's Review button drills into that category's filtered file list.
struct LargeOldFilesDashboardView: View {
    /// All precomputed by the view-model when the file set changes — never
    /// derived here, so a huge scan doesn't re-scan the files on every render.
    let fileCount: Int
    let oldCount: Int
    let totalBytes: Int64
    let tiles: [LargeOldFilesTile]
    let onReview: (LargeOldFilesCategory) -> Void
    /// Opens the complete, unfiltered file list — the analog of the
    /// Applications section's "Manage My Applications".
    let onViewAll: () -> Void
    let onRescan: () -> Void

    /// Fixed width of the hero column so it keeps a stable shape while the right
    /// tiles absorb the remaining width — mirrors `HealthMonitorView`.
    private let leftColumnWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 16) {
            header
            cardLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("large-old.dashboard")
    }

    /// Centred count headline with the two primary actions beneath it, echoing
    /// the Applications dashboard header.
    private var header: some View {
        VStack(spacing: 12) {
            Text(LargeOldFilesSummary.foundSentence(count: fileCount))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("large-old.summary")
            Text(LargeOldFilesSummary.detail(oldCount: oldCount, totalBytes: totalBytes))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(String(
                    localized: "View All Files",
                    comment: "Button that opens the complete, unfiltered Large & Old Files list."
                )) {
                    onViewAll()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("large-old.viewAll")

                Button(String(
                    localized: "Re-scan",
                    comment: "Button that re-runs the Large & Old Files scan from the dashboard."
                )) {
                    onRescan()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("large-old.rescan")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The Health Monitor layout: a tall hero in the left column with a shorter
    /// secondary card tucked beneath it, and the remaining tiles dividing the
    /// right column into equal-height rows of two. Mixing the tall hero, the
    /// compact left card, and the right grid keeps the tiles from all sharing
    /// one size. Lower tile counts degrade gracefully so the pane never shows an
    /// orphaned hero beside empty space.
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
    /// the two read as clearly different sizes — the Health Monitor hero +
    /// `fileVaultCard` stack.
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
    private var nonHeroTiles: [LargeOldFilesTile] { Array(tiles.dropFirst()) }

    /// The smallest non-hero category by reclaimable size becomes the compact
    /// card under the hero — a small tile for a small bucket.
    private var secondaryTile: LargeOldFilesTile? {
        nonHeroTiles.min { $0.totalBytes < $1.totalBytes }
    }

    /// What flows through the right grid: every non-hero tile except the one
    /// shown as the compact left card.
    private var gridTiles: [LargeOldFilesTile] {
        nonHeroTiles.filter { $0.id != secondaryTile?.id }
    }

    /// The non-hero tiles in equal-height rows of two. Grouped in a
    /// `GlassEffectContainer` so adjacent glass cards sample each other and
    /// refract consistently, exactly as the Health Monitor metric grid does.
    private func rightGrid(_ gridTiles: [LargeOldFilesTile]) -> some View {
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
    private func rows(of gridTiles: [LargeOldFilesTile]) -> [[LargeOldFilesTile]] {
        stride(from: 0, to: gridTiles.count, by: 2).map {
            Array(gridTiles[$0..<min($0 + 2, gridTiles.count)])
        }
    }

    private func card(_ tile: LargeOldFilesTile, isHero: Bool) -> some View {
        ApplicationsCard(
            title: tile.category.title,
            metric: LargeOldFilesFormatting.byteFormatter.string(fromByteCount: tile.totalBytes),
            detail: cardDetail(for: tile),
            icon: tile.category.icon,
            actionLabel: String(
                localized: "Review",
                comment: "Large & Old Files tile action that opens the category's file list."
            ),
            identifier: "large-old.card.\(tile.category.rawValue)",
            isHero: isHero,
            action: { onReview(tile.category) }
        )
    }

    private func cardDetail(for tile: LargeOldFilesTile) -> String {
        let count = "\(tile.count) file\(tile.count == 1 ? "" : "s")"
        return "\(count) · \(tile.category.blurb)"
    }
}

/// Header bar above the file list: a count headline with a supporting detail
/// line on the left, and the sort control on the right. Replaces the orphaned
/// toolbar picker so the sort affordance sits with the content it reorders,
/// matching the in-content headers the other section dashboards use.
struct LargeOldFilesResultsHeader: View {
    let fileCount: Int
    let oldCount: Int
    let totalBytes: Int64
    @Binding var sortOrder: LargeOldFilesViewModel.SortOrder

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LargeOldFilesSummary.headline(count: fileCount))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("large-old.summary")
                Text(LargeOldFilesSummary.detail(oldCount: oldCount, totalBytes: totalBytes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            sortPicker
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sortPicker: some View {
        Picker(String(
            localized: "Sort by",
            comment: "Label for the Large & Old Files sort menu."
        ), selection: $sortOrder) {
            Text(String(
                localized: "Largest first",
                comment: "Sort option that orders files from largest to smallest."
            )).tag(LargeOldFilesViewModel.SortOrder.sizeDescending)
            Text(String(
                localized: "Smallest first",
                comment: "Sort option that orders files from smallest to largest."
            )).tag(LargeOldFilesViewModel.SortOrder.sizeAscending)
            Text(String(
                localized: "Oldest first",
                comment: "Sort option that orders files by oldest access date first."
            )).tag(LargeOldFilesViewModel.SortOrder.dateAscending)
            Text(String(
                localized: "Newest first",
                comment: "Sort option that orders files by newest access date first."
            )).tag(LargeOldFilesViewModel.SortOrder.dateDescending)
            Text(String(
                localized: "Name (A–Z)",
                comment: "Sort option that orders files alphabetically by name."
            )).tag(LargeOldFilesViewModel.SortOrder.nameAscending)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("large-old.sort")
    }
}

/// The scan results as a `List` of glass rows — the same pattern every other
/// section uses (System Junk, Applications, Smart Scan). `scrollContentBackground`
/// is hidden so the branded gradient shows through instead of the opaque,
/// accent-tinted row bands a raw `Table` paints over it.
struct LargeOldFilesList: View {
    let files: [ScannedFile]
    var fileIconCache: FileIconCache
    let isSelected: (ScannedFile) -> Bool
    let onToggleSelection: (ScannedFile) -> Void
    let onShowInFinder: (ScannedFile) -> Void
    let onDeleteFile: (ScannedFile) -> Void
    let onAddToExclusions: (ScannedFile) -> Void

    var body: some View {
        List {
            ForEach(files) { file in
                LargeOldFilesRow(
                    file: file,
                    fileIconCache: fileIconCache,
                    isSelected: isSelected(file),
                    onToggleSelection: { onToggleSelection(file) },
                    onShowInFinder: { onShowInFinder(file) },
                    onDelete: { onDeleteFile(file) },
                    onAddToExclusions: { onAddToExclusions(file) }
                )
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("large-old.table")
    }
}

/// One file in the results list: selection checkbox, type icon, name, a
/// secondary "last-accessed · folder" line, and the size as a bold trailing
/// metric. The full path is tail-truncated so the meaningful end stays visible.
struct LargeOldFilesRow: View {
    let file: ScannedFile
    var fileIconCache: FileIconCache
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onShowInFinder: () -> Void
    let onDelete: () -> Void
    let onAddToExclusions: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelection() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(Text(LargeOldFilesFormatting.selectionLabel(for: file)))
            .accessibilityIdentifier("large-old.row.\(file.url.path).checkbox")

            Image(nsImage: fileIconCache.cachedIcon(for: file.url))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(LargeOldFilesFormatting.accessDate(file.lastAccessDate))
                        .layoutPriority(1)
                    Text("·")
                    Text(file.url.deletingLastPathComponent().path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(file.url.path)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(LargeOldFilesFormatting.byteFormatter.string(fromByteCount: file.size))
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityIdentifier("large-old.row.\(file.url.path)")
        .contextMenu {
            Button("Show in Finder") {
                onShowInFinder()
            }
            Button(String(
                localized: "Add to Exclusions",
                comment: "Context menu item that adds the selected file to the scan-exclusions list."
            )) {
                onAddToExclusions()
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }
}

struct LargeOldFilesFooter: View {
    let totalSelectedSize: Int64
    let canDelete: Bool
    let onRescan: () -> Void
    let onDeleteSelected: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LargeOldFilesFormatting.byteFormatter.string(fromByteCount: totalSelectedSize))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("large-old.totalSelected")
            }
            Spacer()
            Button("Re-scan", action: onRescan)
                .accessibilityIdentifier("large-old.rescan")
            Button("Delete Selected", action: onDeleteSelected)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.vaderProminent)
                .disabled(!canDelete)
                .accessibilityIdentifier("large-old.delete")
        }
        .padding(16)
    }
}

struct LargeOldFilesEmptyState: View {
    let onScanAgain: () -> Void
    /// Current Full Disk Access state. Drives whether the inline reminder
    /// appears under the "Scan Again" CTA — without it the user can't tell
    /// whether the empty result is genuine or just FDA-blocked.
    let hasFullDiskAccess: Bool
    /// Re-runs the FDA check. Wired to `AppState.refresh()` so the card can
    /// fade out the moment the user grants access in System Settings.
    let onRefreshAccess: () -> Void

    /// Pure predicate so the gate is unit-testable without rendering. The
    /// per-section "this scan needs FDA" decision lives in
    /// `NavigationSection.requiresFullDiskAccess`; here it is unconditional
    /// because Large & Old Files always requires FDA to read ~/Library.
    var shouldShowFullDiskAccessReminder: Bool { !hasFullDiskAccess }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Nothing to clean up")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("large-old.emptyTitle")
            Text("No files larger than 50 MB or untouched for the past six months were found in your home folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan Again", action: onScanAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("large-old.scanAgain")

            if shouldShowFullDiskAccessReminder {
                FullDiskAccessPromptCard(
                    accent: .teal,
                    onRecheck: onRefreshAccess
                )
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding()
        .animation(.smooth(duration: 0.4), value: hasFullDiskAccess)
    }
}

struct LargeOldFilesFailedState: View {
    let stage: LargeOldFilesViewModel.FailureStage
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(stage == .scanning ? "Couldn't complete the scan" : "Couldn't finish deleting")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("large-old.errorMessage")
            Button("Try Again", action: onTryAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("large-old.tryAgain")
        }
        .padding()
    }
}

extension ScannedFile: Identifiable {
    var id: URL { url }
}

#Preview("Large Old Files Footer") {
    LargeOldFilesFooter(
        totalSelectedSize: 128_000_000,
        canDelete: true,
        onRescan: {},
        onDeleteSelected: {}
    )
    .frame(width: 800)
}
