// MyClutterDashboardView.swift
// Post-scan landing for My Clutter: a centered "files to sort through" header with a Review All Files action, above a four-card recommendation grid (Duplicates, Similar Images, Large & Old, Downloads) with real file thumbnails.

import SwiftUI
import QuickLookThumbnailing
import AppKit

/// One card on the My Clutter dashboard: a clutter category with findings, or
/// an "all good" reassurance card used to backfill the grid to its minimum
/// count when a scan finds fewer than two categories.
enum MyClutterTileKind: Identifiable, Equatable {
    case duplicates
    case similar
    case largeOld
    case downloads
    case reassurance(ReassuranceContent)

    var id: String {
        switch self {
        case .duplicates:               return "duplicates"
        case .similar:                  return "similar"
        case .largeOld:                 return "largeOld"
        case .downloads:                return "downloads"
        case .reassurance(let content): return "reassurance.\(content.id)"
        }
    }

    /// The ranked 2–4 cards the dashboard shows: the categories that actually
    /// found files, largest reclaimable size first (capped at four), backfilled
    /// with reassurance cards when a scan finds fewer than two categories. Each
    /// category is passed as a `(count, bytes)` pair so an empty category is
    /// dropped even if its byte total rounds to zero.
    static func recommended(duplicates: (count: Int, bytes: Int64),
                            similar: (count: Int, bytes: Int64),
                            largeOld: (count: Int, bytes: Int64),
                            downloads: (count: Int, bytes: Int64)) -> [MyClutterTileKind] {
        var candidates: [RankedTile<MyClutterTileKind>] = []
        func add(_ kind: MyClutterTileKind, _ category: (count: Int, bytes: Int64)) {
            guard category.count > 0 else { return }
            candidates.append(RankedTile(payload: kind, urgency: .space, reclaimableBytes: category.bytes))
        }
        add(.duplicates, duplicates)
        add(.similar, similar)
        add(.largeOld, largeOld)
        add(.downloads, downloads)

        let reassurance = reassurancePool.map { content in
            RankedTile(payload: MyClutterTileKind.reassurance(content), urgency: .reassurance, reclaimableBytes: 0)
        }
        return SectionRecommendationSelector.select(real: candidates, reassurance: reassurance)
    }

    /// Ordered pool of "all good" cards, drawn from in order when a scan finds
    /// fewer than two categories so backfilling never repeats a card.
    static let reassurancePool: [ReassuranceContent] = [
        ReassuranceContent(
            id: "myClutter.organized",
            title: String(localized: "Nicely Organized", comment: "My Clutter reassurance card title."),
            detail: String(
                localized: "No duplicates, look-alikes, or space hogs stood out in this scan.",
                comment: "My Clutter reassurance card detail."
            ),
            icon: "checkmark.seal"
        ),
        ReassuranceContent(
            id: "myClutter.reviewAll",
            title: String(localized: "Browse Everything", comment: "My Clutter reassurance card title."),
            detail: String(
                localized: "Use Review All Files to look through your files whenever you like.",
                comment: "My Clutter reassurance card detail."
            ),
            icon: "folder"
        ),
    ]
}

/// The My Clutter results dashboard. A "Start Over" bar, a centered header
/// counting the files to sort through with a "Review All Files" button, then the
/// four recommendation cards laid out as a tall Duplicates card on the left and
/// a Similar Images card over a Large & Old / Downloads pair on the right.
struct MyClutterDashboardView: View {
    let viewModel: MyClutterViewModel
    let accent: Color
    let onReviewAll: () -> Void
    let onReviewDuplicates: () -> Void
    let onReviewSimilar: () -> Void
    let onReviewLargeOld: () -> Void
    let onReviewDownloads: () -> Void
    let onStartOver: () -> Void

    // Allocated once for the process: `ByteCountFormatter` builds measurable
    // internal state per instance, so a stored static avoids rebuilding it on
    // each access during a render. Matches the convention used across the app's
    // other dashboards.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            startOverBar
            VStack(spacing: 18) {
                header
                grid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("myClutter.dashboard")
    }

    // MARK: - Start Over

    private var startOverBar: some View {
        HStack {
            Button(action: onStartOver) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(String(localized: "Start Over", comment: "Discards the scan and returns to the My Clutter intro."))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("myClutter.startOver")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            Image("largeOldFiles")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 140, maxHeight: 140)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(headlineLine)
                    .font(.title.weight(.semibold))
                Text(String(
                    localized: "Use quick recommendations or review them by hand.",
                    comment: "My Clutter dashboard subheadline."
                ))
                .font(.title3)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .accessibilityIdentifier("myClutter.summary")

            Button(action: onReviewAll) {
                Text(String(localized: "Review All Files", comment: "Opens the complete review across every My Clutter category."))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.vaderTileGlass)
            .controlSize(.large)
            .accessibilityIdentifier("myClutter.reviewAll")
        }
    }

    private var headlineLine: String {
        let format = String(
            localized: "You have %lld files to sort through.",
            comment: "My Clutter dashboard headline; %lld is the total candidate file count."
        )
        return String.localizedStringWithFormat(format, viewModel.totalFileCount)
    }

    // MARK: - Grid

    /// Fixed width of the hero column so the lead card keeps a stable shape while
    /// the remaining cards absorb the rest of the width — mirrors the Cleanup
    /// dashboard so the two sections share one look.
    private let heroColumnWidth: CGFloat = 340

    /// The ranked 2–4 cards this scan warrants, largest reclaimable size first.
    private var recommendedTiles: [MyClutterTileKind] {
        MyClutterTileKind.recommended(
            duplicates: (viewModel.duplicateCopies.count, viewModel.duplicateReclaimableBytes),
            similar: (viewModel.similarCopies.count, viewModel.similarReclaimableBytes),
            largeOld: (viewModel.largeOldFiles.count, viewModel.largeOldBytes),
            downloads: (viewModel.downloads.count, viewModel.downloadsBytes)
        )
    }

    /// The bento grid: the top-ranked card leads on the left, the rest fill the
    /// right column (a wide card on top, the remainder in rows of two). Lower
    /// card counts degrade gracefully so the pane never shows a lone card beside
    /// empty space.
    @ViewBuilder
    private var grid: some View {
        let tiles = recommendedTiles
        switch tiles.count {
        case 0:
            EmptyView()
        case 1:
            card(tiles[0])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            // One container so the adjacent glass tiles sample each other and
            // refract consistently; spacing stays below the 16pt grid gap so
            // they never blend into one blob.
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    card(tiles[0])
                        .frame(width: heroColumnWidth)
                        .frame(maxHeight: .infinity)
                    rightColumn(Array(tiles.dropFirst()))
                }
            }
        }
    }

    /// The non-hero cards: the first is a wide card spanning the column, the rest
    /// flow in rows of two beneath it.
    private func rightColumn(_ rest: [MyClutterTileKind]) -> some View {
        VStack(spacing: 16) {
            if let wide = rest.first {
                card(wide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(Array(rows(of: Array(rest.dropFirst())).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    ForEach(row) { tile in
                        card(tile)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Chunks the remaining cards into rows of at most two so the lower grid
    /// reads as a balanced two-up arrangement.
    private func rows(of tiles: [MyClutterTileKind]) -> [[MyClutterTileKind]] {
        stride(from: 0, to: tiles.count, by: 2).map {
            Array(tiles[$0..<min($0 + 2, tiles.count)])
        }
    }

    /// Renders one ranked tile with its category card, or a reassurance backfill.
    @ViewBuilder
    private func card(_ kind: MyClutterTileKind) -> some View {
        switch kind {
        case .duplicates:               duplicatesCard
        case .similar:                  similarCard
        case .largeOld:                 largeOldCard
        case .downloads:                downloadsCard
        case .reassurance(let content): ReassuranceCard(content: content, accent: accent)
        }
    }

    // MARK: - Cards

    private var duplicatesCard: some View {
        MyClutterCard(
            title: String.localizedStringWithFormat(
                String(localized: "%lld Duplicates Found", comment: "Duplicates card title; %lld is the count."),
                viewModel.duplicateCopies.count
            ),
            subtitle: String.localizedStringWithFormat(
                String(localized: "Remove %@ of duplicate files.", comment: "Duplicates card subtitle; %@ is a size."),
                Self.byteFormatter.string(fromByteCount: viewModel.duplicateReclaimableBytes)
            ),
            accent: accent,
            thumbnails: Array(viewModel.duplicateCopies.prefix(3).map(\.url)),
            fallbackSymbol: "doc.on.doc.fill",
            identifier: "myClutter.card.duplicates",
            isEnabled: !viewModel.duplicateCopies.isEmpty,
            placement: .center,
            onReview: onReviewDuplicates
        )
    }

    private var similarCard: some View {
        MyClutterCard(
            title: String.localizedStringWithFormat(
                String(localized: "%lld Similar Images Found", comment: "Similar Images card title; %lld is the count."),
                viewModel.similarCopies.count
            ),
            subtitle: String.localizedStringWithFormat(
                String(localized: "%@ of nearly identical photos.", comment: "Similar Images card subtitle; %@ is a size."),
                Self.byteFormatter.string(fromByteCount: viewModel.similarReclaimableBytes)
            ),
            accent: accent,
            thumbnails: Array(viewModel.similarCopies.prefix(3).map(\.url)),
            fallbackSymbol: "photo.on.rectangle.angled",
            identifier: "myClutter.card.similar",
            isEnabled: !viewModel.similarCopies.isEmpty,
            onReview: onReviewSimilar
        )
    }

    private var largeOldCard: some View {
        MyClutterCard(
            title: String.localizedStringWithFormat(
                String(localized: "%@ of Large and Old Files Found", comment: "Large & Old card title; %@ is a size."),
                Self.byteFormatter.string(fromByteCount: viewModel.largeOldBytes)
            ),
            subtitle: nil,
            accent: accent,
            thumbnails: Array(viewModel.largeOldFiles.prefix(1).map(\.url)),
            fallbackSymbol: "doc.fill",
            identifier: "myClutter.card.largeOld",
            isEnabled: !viewModel.largeOldFiles.isEmpty,
            showsThumbnailChrome: false,
            onReview: onReviewLargeOld
        )
    }

    private var downloadsCard: some View {
        MyClutterCard(
            title: downloadsTitle,
            subtitle: nil,
            accent: accent,
            thumbnails: Array(viewModel.downloads.prefix(1).map(\.file.url)),
            fallbackSymbol: "arrow.down.circle.fill",
            identifier: "myClutter.card.downloads",
            isEnabled: !viewModel.downloads.isEmpty,
            accessoryImage: downloadsSourceIcon,
            onReview: onReviewDownloads
        )
    }

    /// The downloading app's real icon (e.g. Google Chrome), shown in the
    /// Downloads card corner. `nil` when the source is unknown or the app isn't
    /// installed, so the card falls back to a file thumbnail.
    private var downloadsSourceIcon: NSImage? {
        AppIconLoader.image(bundleID: viewModel.dominantDownloadBundleID)
    }

    private var downloadsTitle: String {
        let size = Self.byteFormatter.string(fromByteCount: viewModel.downloadsBytes)
        if let source = viewModel.dominantDownloadSource {
            let format = String(
                localized: "%1$@ of %2$@ Downloads Found",
                comment: "Downloads card title; %1$@ is a size, %2$@ is the source app, e.g. Google Chrome."
            )
            return String.localizedStringWithFormat(format, size, source)
        }
        let format = String(localized: "%@ of Downloads Found", comment: "Downloads card title; %@ is a size.")
        return String.localizedStringWithFormat(format, size)
    }
}

// MARK: - Card

/// A single recommendation card: a translucent rounded panel with a title, an
/// optional subtitle, file thumbnails (or a source-app icon), and a "Review"
/// button pinned bottom-trailing. Disabled (and dimmed) when its category is
/// empty.
struct MyClutterCard: View {
    /// Where the card's imagery sits: tucked in the top-right corner, or
    /// enlarged and centered in the card body (the Duplicates card).
    enum ThumbnailPlacement {
        case corner
        case center
    }

    let title: String
    let subtitle: String?
    let accent: Color
    let thumbnails: [URL]
    let fallbackSymbol: String
    let identifier: String
    let isEnabled: Bool
    var placement: ThumbnailPlacement = .corner
    /// When set (e.g. a browser's app icon for the Downloads card), shown in the
    /// corner instead of file thumbnails.
    var accessoryImage: NSImage? = nil
    /// Whether thumbnails get the dark rounded backing + border + shadow. Off
    /// for cards whose imagery already reads as a standalone icon (Large & Old).
    var showsThumbnailChrome: Bool = true
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch placement {
            case .center:
                titleBlock
                Spacer(minLength: 12)
                centeredThumbnails
                Spacer(minLength: 12)
            case .corner:
                HStack(alignment: .top, spacing: 12) {
                    titleBlock
                    Spacer(minLength: 8)
                    cornerAccessory
                }
                Spacer(minLength: 12)
            }
            reviewRow
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaderTileGlass()
        .opacity(isEnabled ? 1 : 0.7)
        .accessibilityIdentifier(identifier)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reviewRow: some View {
        HStack {
            Spacer()
            if isEnabled {
                Button(action: onReview) {
                    Text(String(localized: "Review", comment: "Opens the review screen for a My Clutter card."))
                }
                .buttonStyle(.vaderGlass)
                .accessibilityIdentifier("\(identifier).review")
            } else {
                Text(String(localized: "All clear", comment: "Shown on a My Clutter card whose category found nothing."))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// The top-right corner imagery: an explicit accessory icon when provided
    /// (the Downloads card's browser icon), else up to three overlapping
    /// thumbnails, else the fallback symbol.
    @ViewBuilder
    private var cornerAccessory: some View {
        if let accessoryImage {
            Image(nsImage: accessoryImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 46, height: 46)
        } else if thumbnails.isEmpty {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 34))
                .foregroundStyle(accent)
        } else {
            HStack(spacing: -10) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, url in
                    thumbnail(url, size: 46)
                }
            }
        }
    }

    /// Enlarged thumbnails spaced across the centre of the card body, matching
    /// the reference Duplicates card.
    @ViewBuilder
    private var centeredThumbnails: some View {
        if thumbnails.isEmpty {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 46))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 22) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, url in
                    thumbnail(url, size: 76)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// One thumbnail at the given side length. The dark backing/border/shadow
    /// is dropped when `showsThumbnailChrome` is false so the icon reads on its
    /// own against the card.
    @ViewBuilder
    private func thumbnail(_ url: URL, size: CGFloat) -> some View {
        if showsThumbnailChrome {
            ClutterThumbnailView(url: url, fallbackSymbol: fallbackSymbol)
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        } else {
            ClutterThumbnailView(url: url, fallbackSymbol: fallbackSymbol, contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Thumbnail

/// Loads a real Quick Look thumbnail for a file asynchronously, falling back to
/// the file's Finder icon and finally an SF Symbol. Used for the card corner
/// imagery so photos show their actual content.
struct ClutterThumbnailView: View {
    let url: URL
    let fallbackSymbol: String
    /// Point size requested from Quick Look — small for card corners, large for
    /// the manager's preview pane.
    var pointSize: CGFloat = 92
    /// How the loaded image fills its frame. Card thumbnails fill (cropped);
    /// the preview pane fits (whole image visible).
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    init(url: URL, fallbackSymbol: String, pointSize: CGFloat = 92, contentMode: ContentMode = .fill) {
        self.url = url
        self.fallbackSymbol = fallbackSymbol
        self.pointSize = pointSize
        self.contentMode = contentMode
        // Seed synchronously from the process-wide cache so a repeat visit to
        // My Clutter paints the real thumbnail on the first frame — no fallback
        // flash and no Quick Look work.
        _image = State(initialValue: ClutterThumbnailCache.cached(url, pointSize: pointSize))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            // Cache-first: a hit resolves instantly (also covers a `url` change
            // on a reused view instance); a miss generates once and caches the
            // result for the next visit.
            if let cached = ClutterThumbnailCache.cached(url, pointSize: pointSize) {
                image = cached
                return
            }
            let generated = await Self.thumbnail(for: url, pointSize: pointSize)
            if let generated {
                ClutterThumbnailCache.store(generated, for: url, pointSize: pointSize)
            }
            image = generated
        }
    }

    /// Generates a Quick Look thumbnail, falling back to the Finder icon.
    /// iCloud placeholders use the icon directly — asking Quick Look to render
    /// one would force a slow on-demand download.
    private static func thumbnail(for url: URL, pointSize: CGFloat) async -> NSImage? {
        guard CloudFileAvailability.isLocallyAvailable(url) else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let size = CGSize(width: pointSize, height: pointSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
