// MyClutterDashboardView.swift
// Post-scan landing for My Clutter: a centered "files to sort through" header with a Review All Files action, above a four-card recommendation grid (Duplicates, Similar Images, Large & Old, Downloads) with real file thumbnails.

import SwiftUI
import QuickLookThumbnailing
import AppKit

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

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }

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
            .buttonStyle(.bordered)
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

    private var grid: some View {
        HStack(alignment: .top, spacing: 16) {
            duplicatesCard
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 16) {
                similarCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 16) {
                    largeOldCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    downloadsCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                byteFormatter.string(fromByteCount: viewModel.duplicateReclaimableBytes)
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
                byteFormatter.string(fromByteCount: viewModel.similarReclaimableBytes)
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
                byteFormatter.string(fromByteCount: viewModel.largeOldBytes)
            ),
            subtitle: nil,
            accent: accent,
            thumbnails: Array(viewModel.largeOldFiles.prefix(1).map(\.url)),
            fallbackSymbol: "doc.fill",
            identifier: "myClutter.card.largeOld",
            isEnabled: !viewModel.largeOldFiles.isEmpty,
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

    /// The downloading browser's real app icon (e.g. Google Chrome), shown in
    /// the Downloads card corner. `nil` when the source is unknown or the app
    /// isn't installed, so the card falls back to a file thumbnail.
    private var downloadsSourceIcon: NSImage? {
        guard
            let source = viewModel.dominantDownloadSource,
            let bundleID = DownloadsScanner.bundleIdentifier(forSource: source),
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private var downloadsTitle: String {
        let size = byteFormatter.string(fromByteCount: viewModel.downloadsBytes)
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
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
                    .foregroundStyle(.white.opacity(0.7))
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
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.bordered)
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

    /// One framed thumbnail at the given side length.
    private func thumbnail(_ url: URL, size: CGFloat) -> some View {
        ClutterThumbnailView(url: url, fallbackSymbol: fallbackSymbol)
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}

// MARK: - Thumbnail

/// Loads a real Quick Look thumbnail for a file asynchronously, falling back to
/// the file's Finder icon and finally an SF Symbol. Used for the card corner
/// imagery so photos show their actual content.
struct ClutterThumbnailView: View {
    let url: URL
    let fallbackSymbol: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            image = await Self.thumbnail(for: url)
        }
    }

    /// Generates a Quick Look thumbnail, falling back to the Finder icon.
    /// iCloud placeholders use the icon directly — asking Quick Look to render
    /// one would force a slow on-demand download.
    private static func thumbnail(for url: URL) async -> NSImage? {
        guard CloudFileAvailability.isLocallyAvailable(url) else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let size = CGSize(width: 92, height: 92)
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
