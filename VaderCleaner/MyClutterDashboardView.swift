// MyClutterDashboardView.swift
// Post-scan landing for My Clutter: a centered "files to sort through" header with a Review All Files action, above a four-card recommendation grid (Duplicates, Similar Images, Large & Old, Downloads) with real file thumbnails.

import SwiftUI
import AppKit
import VaderCleanerCore

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

/// The My Clutter results dashboard: the shared `SectionDashboard` counting the
/// files to sort through, a "Review All Files" action, and a card per clutter
/// category with findings, largest reclaimable size leading. The cards show
/// real file thumbnails (or the downloading app's icon) rather than a category
/// badge, because the files themselves say more.
struct MyClutterDashboardView: View {
    let viewModel: MyClutterViewModel
    let onReviewAll: () -> Void
    let onReviewDuplicates: () -> Void
    let onReviewSimilar: () -> Void
    let onReviewLargeOld: () -> Void
    let onReviewDownloads: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        SectionDashboard(
            section: .largeOldFiles,
            headline: headlineLine,
            subheadline: String(
                localized: "Use quick recommendations or review them by hand.",
                comment: "My Clutter dashboard subheadline."
            ),
            headlineIdentifier: "myClutter.summary",
            headerAction: DashboardHeaderAction(
                title: String(localized: "Review All Files", comment: "Opens the complete review across every My Clutter category."),
                identifier: "myClutter.reviewAll",
                action: onReviewAll
            ),
            // A scan started now could list a file the removal is about to move,
            // and that file would then read as one that couldn't be Trashed.
            startOver: DashboardStartOver(
                identifier: "myClutter.startOver",
                isDisabled: viewModel.isRemoving,
                action: onStartOver
            ),
            identifier: "myClutter.dashboard"
        ) {
            DashboardGrid(tiles: recommendedTiles) { kind, role in
                card(kind, role: role)
            }
        }
    }

    private var headlineLine: String {
        let format = String(
            localized: "You have %lld files to sort through.",
            comment: "My Clutter dashboard headline; %lld is the total candidate file count."
        )
        return String.localizedStringWithFormat(format, viewModel.totalFileCount)
    }

    /// The ranked 2–4 cards this scan warrants, largest reclaimable size first.
    private var recommendedTiles: [MyClutterTileKind] {
        MyClutterTileKind.recommended(
            duplicates: (viewModel.duplicateCopies.count, viewModel.duplicateReclaimableBytes),
            similar: (viewModel.similarCopies.count, viewModel.similarReclaimableBytes),
            largeOld: (viewModel.largeOldFiles.count, viewModel.largeOldBytes),
            downloads: (viewModel.downloads.count, viewModel.downloadsBytes)
        )
    }

    /// Renders one ranked tile with its category card, or a reassurance backfill.
    @ViewBuilder
    private func card(_ kind: MyClutterTileKind, role: DashboardTileRole) -> some View {
        switch kind {
        case .duplicates:               duplicatesCard(role: role)
        case .similar:                  similarCard(role: role)
        case .largeOld:                 largeOldCard(role: role)
        case .downloads:                downloadsCard(role: role)
        case .reassurance(let content): DashboardReassuranceCard(content: content, role: role)
        }
    }

    private func duplicatesCard(role: DashboardTileRole) -> some View {
        let urls = Array(viewModel.duplicateCopies.prefix(3).map(\.url))
        return categoryCard(
            title: Self.duplicatesTitle(bytes: viewModel.duplicateReclaimableBytes),
            detail: Self.duplicatesDetail(count: viewModel.duplicateCopies.count),
            identifier: "myClutter.card.duplicates",
            role: role,
            onReview: onReviewDuplicates
        ) {
            ClutterThumbnailStack(urls: urls, fallbackSymbol: "doc.on.doc.fill",
                                  size: ClutterThumbnailStack.accessorySize)
        } illustration: {
            ClutterThumbnailStack(urls: urls, fallbackSymbol: "doc.on.doc.fill",
                                  size: ClutterThumbnailStack.illustrationSize)
        }
    }

    private func similarCard(role: DashboardTileRole) -> some View {
        let urls = Array(viewModel.similarCopies.prefix(3).map(\.url))
        return categoryCard(
            title: Self.similarTitle(bytes: viewModel.similarReclaimableBytes),
            detail: Self.similarDetail(count: viewModel.similarCopies.count),
            identifier: "myClutter.card.similar",
            role: role,
            onReview: onReviewSimilar
        ) {
            ClutterThumbnailStack(urls: urls, fallbackSymbol: "photo.on.rectangle.angled",
                                  size: ClutterThumbnailStack.accessorySize)
        } illustration: {
            ClutterThumbnailStack(urls: urls, fallbackSymbol: "photo.on.rectangle.angled",
                                  size: ClutterThumbnailStack.illustrationSize)
        }
    }

    private func largeOldCard(role: DashboardTileRole) -> some View {
        categoryCard(
            title: String.localizedStringWithFormat(
                String(localized: "%@ of Large and Old Files Found", comment: "Large & Old card title; %@ is a size."),
                formattedFileBytes(viewModel.largeOldBytes)
            ),
            detail: Self.largeOldDetail(count: viewModel.largeOldFiles.count),
            identifier: "myClutter.card.largeOld",
            role: role,
            onReview: onReviewLargeOld
        ) {
            // A large file's thumbnail is usually its own icon, so it goes
            // without the photo backing.
            ClutterThumbnailStack(urls: Array(viewModel.largeOldFiles.prefix(1).map(\.url)),
                                  fallbackSymbol: "doc.fill",
                                  size: ClutterThumbnailStack.accessorySize,
                                  showsChrome: false)
        } illustration: {
            ClutterThumbnailStack(urls: Array(viewModel.largeOldFiles.prefix(3).map(\.url)),
                                  fallbackSymbol: "doc.fill",
                                  size: ClutterThumbnailStack.illustrationSize,
                                  showsChrome: false)
        }
    }

    private func downloadsCard(role: DashboardTileRole) -> some View {
        categoryCard(
            title: downloadsTitle,
            detail: Self.downloadsDetail(count: viewModel.downloads.count),
            identifier: "myClutter.card.downloads",
            role: role,
            onReview: onReviewDownloads
        ) {
            downloadsImagery(size: ClutterThumbnailStack.accessorySize)
        } illustration: {
            downloadsImagery(size: ClutterThumbnailStack.illustrationSize)
        }
    }

    private func categoryCard<Accessory: View, Illustration: View>(
        title: String,
        detail: String,
        identifier: String,
        role: DashboardTileRole,
        onReview: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder illustration: () -> Illustration
    ) -> some View {
        DashboardCard(
            title: title,
            detail: detail,
            role: role,
            actions: [DashboardCardAction(
                title: String(localized: "Review", comment: "Opens the review screen for a My Clutter card."),
                prominence: .secondary,
                identifier: "\(identifier).review",
                action: onReview
            )],
            accessory: accessory,
            illustration: illustration
        )
        .accessibilityIdentifier(identifier)
    }

    /// The downloading app's real icon (e.g. Google Chrome) when it is known
    /// and installed, else the first download's thumbnail.
    @ViewBuilder
    private func downloadsImagery(size: CGFloat) -> some View {
        if let icon = AppIconLoader.image(bundleID: viewModel.dominantDownloadBundleID) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            ClutterThumbnailStack(
                urls: Array(viewModel.downloads.prefix(1).map(\.file.url)),
                fallbackSymbol: "arrow.down.circle.fill",
                size: size
            )
        }
    }

    private var downloadsTitle: String {
        let size = formattedFileBytes(viewModel.downloadsBytes)
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

    // MARK: Copy

    static func duplicatesTitle(bytes: Int64) -> String {
        String.localizedStringWithFormat(
            String(localized: "%@ of Duplicates Found", comment: "Duplicates card title; %@ is the reclaimable size."),
            formattedFileBytes(bytes)
        )
    }

    static func duplicatesDetail(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "%lld duplicate copies you can remove.", comment: "Duplicates card detail; %lld is the number of copies."),
            count
        )
    }

    static func similarTitle(bytes: Int64) -> String {
        String.localizedStringWithFormat(
            String(localized: "%@ of Similar Images Found", comment: "Similar Images card title; %@ is the reclaimable size."),
            formattedFileBytes(bytes)
        )
    }

    static func similarDetail(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "%lld nearly identical photos.", comment: "Similar Images card detail; %lld is the number of photos."),
            count
        )
    }

    static func largeOldDetail(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "%lld large or long-unopened files.", comment: "Large & Old card detail; %lld is the number of files."),
            count
        )
    }

    static func downloadsDetail(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "%lld downloaded files to look through.", comment: "Downloads card detail; %lld is the number of files."),
            count
        )
    }
}

// MARK: - Thumbnail stack

/// Up to three real file thumbnails side by side: overlapping in a card's
/// corner, spaced out when centered in the lead card. Falls back to an orb
/// with the category's symbol when there is nothing to show.
struct ClutterThumbnailStack: View {
    static let accessorySize: CGFloat = 46
    static let illustrationSize: CGFloat = 76

    let urls: [URL]
    let fallbackSymbol: String
    let size: CGFloat
    /// Whether thumbnails get the dark rounded backing, border, and shadow. Off
    /// for imagery that already reads as a standalone icon.
    var showsChrome = true

    private var isCentered: Bool { size > Self.accessorySize }

    var body: some View {
        if urls.isEmpty {
            DashboardOrb(
                symbol: fallbackSymbol,
                size: isCentered ? DashboardOrb.illustrationSize : DashboardOrb.accessorySize
            )
        } else {
            HStack(spacing: isCentered ? 22 : -10) {
                ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                    thumbnail(url)
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ url: URL) -> some View {
        if showsChrome {
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
            // A reused view is still showing the previous file. The preview pane
            // puts this picture beside the new file's details, and someone may
            // choose what to remove from that, so show nothing rather than the
            // wrong image.
            image = nil
            let loaded = await ClutterThumbnailCache.load(url, pointSize: pointSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
