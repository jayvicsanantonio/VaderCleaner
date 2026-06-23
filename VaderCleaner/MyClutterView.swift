// MyClutterView.swift
// My Clutter section detail: switches between the scanning state, the four-card results dashboard, and the per-card (or all-files) review screens, which reuse the shared three-pane review manager over the orchestrator's results.

import SwiftUI

/// Detail view for the My Clutter section. Owns the transient "which review is
/// open" navigation state and renders the dashboard, the review screens, or the
/// scan/empty states based on the view-model's phase.
struct MyClutterView: View {
    @Bindable var viewModel: MyClutterViewModel
    @Environment(AppState.self) private var appState

    private let accent = NavigationSection.largeOldFiles.theme.accent

    /// Which review screen is up, or `nil` for the dashboard.
    @State private var review: ReviewTarget?

    /// A review destination: one card's category, or every category at once.
    enum ReviewTarget: Equatable {
        case duplicates
        case similar
        case largeOld
        case downloads
        case all
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.largeOldFiles.title)
            .environment(\.sectionAccent, accent)
            .onChange(of: viewModel.phase) { _, newPhase in
                // Leaving results always drops any open review so a stale one
                // never re-emerges on the next scan.
                if newPhase != .results { review = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            // ContentView shows the shared intro while idle; never built here.
            EmptyView()
        case .scanning:
            LargeOldFilesProgressState(
                label: String(localized: "Scanning…", comment: "My Clutter scanning status."),
                identifier: "myClutter.scanning",
                detail: ScanProgressFormatting.itemsScanned(viewModel.scannedItemCount),
                phrases: ScanPhrases.scanning(for: .largeOldFiles)
            )
        case .empty:
            LargeOldFilesEmptyState(
                onScanAgain: viewModel.scanAgain,
                hasFullDiskAccess: appState.hasFullDiskAccess,
                onRefreshAccess: { appState.refresh() }
            )
        case .failed(let message):
            LargeOldFilesFailedState(stage: .scanning, message: message, onTryAgain: viewModel.scanAgain)
        case .results:
            if let review {
                reviewScreen(for: review)
            } else {
                dashboard
            }
        }
    }

    private var dashboard: some View {
        MyClutterDashboardView(
            viewModel: viewModel,
            accent: accent,
            onReviewAll: { review = .all },
            onReviewDuplicates: { review = .duplicates },
            onReviewSimilar: { review = .similar },
            onReviewLargeOld: { review = .largeOld },
            onReviewDownloads: { review = .downloads },
            onStartOver: viewModel.scanAgain
        )
    }

    // MARK: - Review

    private func reviewScreen(for target: ReviewTarget) -> some View {
        // Snapshot the data the off-main builder needs as plain value types.
        let duplicates = viewModel.duplicateGroups
        let similar = viewModel.similarGroups
        let largeOld = viewModel.largeOldFiles
        let downloads = viewModel.downloads

        return SmartScanReviewManager(
            title: title(for: target),
            buildSections: {
                Self.sections(
                    for: target,
                    duplicates: duplicates,
                    similar: similar,
                    largeOld: largeOld,
                    downloads: downloads
                )
            },
            isSelected: { id in viewModel.isSelected(URL(fileURLWithPath: id)) },
            onToggle: { id in viewModel.toggleSelection(path: id) },
            onSetCategory: { category, selected in
                let urls = category.items.map { URL(fileURLWithPath: $0.id) }
                viewModel.setSelection(urls, selected: selected)
            },
            categorySelectedBytes: { category in
                let urls = category.items.map { URL(fileURLWithPath: $0.id) }
                let bytes = viewModel.selectedBytes(in: urls)
                return bytes > 0 ? bytes : nil
            },
            onBack: { review = nil },
            accessibilityPrefix: "myClutter.review",
            primaryActionTitle: String(localized: "Move to Trash", comment: "Footer button that trashes the selected My Clutter files."),
            onPrimaryAction: {
                Task {
                    await viewModel.deleteSelected()
                    if viewModel.totalFileCount == 0 { review = nil }
                }
            },
            primaryActionEnabled: !viewModel.selectedURLs.isEmpty,
            selectionSummary: {
                ManagerSelectionSummary(count: viewModel.selectedURLs.count, bytes: viewModel.totalSelectedSize)
            }
        )
    }

    private func title(for target: ReviewTarget) -> String {
        switch target {
        case .duplicates: return String(localized: "Duplicates", comment: "Duplicates review title.")
        case .similar: return String(localized: "Similar Images", comment: "Similar Images review title.")
        case .largeOld: return String(localized: "Large & Old Files", comment: "Large & Old Files review title.")
        case .downloads: return String(localized: "Downloads", comment: "Downloads review title.")
        case .all: return String(localized: "My Clutter", comment: "All-files review title.")
        }
    }

    // MARK: - Section builders (pure, off-main)

    nonisolated private static func sections(
        for target: ReviewTarget,
        duplicates: [DuplicateGroup],
        similar: [SimilarImageGroup],
        largeOld: [ScannedFile],
        downloads: [DownloadItem]
    ) -> [ManagerSection] {
        switch target {
        case .duplicates:
            return [duplicatesSection(duplicates)].compactMap { $0 }
        case .similar:
            return [similarSection(similar)].compactMap { $0 }
        case .largeOld:
            return [largeOldSection(largeOld)].compactMap { $0 }
        case .downloads:
            return [downloadsSection(downloads)].compactMap { $0 }
        case .all:
            return [
                duplicatesSection(duplicates),
                similarSection(similar),
                largeOldSection(largeOld),
                downloadsSection(downloads),
            ].compactMap { $0 }
        }
    }

    /// One category per duplicate group; items are the redundant copies (the
    /// kept original is named in the title but never listed).
    nonisolated private static func duplicatesSection(_ groups: [DuplicateGroup]) -> ManagerSection? {
        let categories = groups.compactMap { group -> ManagerCategory? in
            let copies = group.redundantCopies
            guard !copies.isEmpty else { return nil }
            let total = group.reclaimableBytes
            return ManagerCategory(
                id: group.original.url.path,
                title: String.localizedStringWithFormat(
                    String(localized: "Copies of “%@”", comment: "Duplicates category title; %@ is the kept file name."),
                    group.original.url.lastPathComponent
                ),
                systemImage: "doc.on.doc.fill",
                tint: .orange,
                items: copies.map(item(for:)),
                totalSize: total,
                totalSizeText: ManagerByteText.string(total)
            )
        }
        guard !categories.isEmpty else { return nil }
        return ManagerSection(
            id: "duplicates",
            title: String(localized: "Duplicates", comment: "Duplicates review section title."),
            categories: categories
        )
    }

    /// One category per similar-image group; items are the redundant copies.
    nonisolated private static func similarSection(_ groups: [SimilarImageGroup]) -> ManagerSection? {
        let categories = groups.compactMap { group -> ManagerCategory? in
            let copies = group.redundantCopies
            guard !copies.isEmpty else { return nil }
            let total = group.reclaimableBytes
            return ManagerCategory(
                id: group.original.url.path,
                title: String.localizedStringWithFormat(
                    String(localized: "Similar to “%@”", comment: "Similar Images category title; %@ is the kept file name."),
                    group.original.url.lastPathComponent
                ),
                systemImage: "photo.fill",
                tint: .purple,
                items: copies.map(item(for:)),
                totalSize: total,
                totalSizeText: ManagerByteText.string(total)
            )
        }
        guard !categories.isEmpty else { return nil }
        return ManagerSection(
            id: "similar",
            title: String(localized: "Similar Images", comment: "Similar Images review section title."),
            categories: categories
        )
    }

    /// A single category listing the large & old files, capped to the actionable
    /// top slice so opening the manager over a huge result set stays responsive.
    nonisolated private static func largeOldSection(_ files: [ScannedFile]) -> ManagerSection? {
        guard !files.isEmpty else { return nil }
        let capped = Array(files.sorted { $0.size > $1.size }.prefix(2000))
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let category = ManagerCategory(
            id: "largeOld",
            title: String(localized: "Large and Old Files", comment: "Large & Old review category title."),
            systemImage: "doc.fill",
            tint: .blue,
            items: capped.map(item(for:)),
            totalSize: total,
            totalSizeText: ManagerByteText.string(total)
        )
        return ManagerSection(
            id: "largeOld",
            title: String(localized: "Large & Old Files", comment: "Large & Old review section title."),
            categories: [category]
        )
    }

    /// Downloads grouped into one category per source app (Chrome, Safari, …),
    /// with an "Other" bucket for files with no recorded source.
    nonisolated private static func downloadsSection(_ items: [DownloadItem]) -> ManagerSection? {
        guard !items.isEmpty else { return nil }
        var bySource: [String: [ScannedFile]] = [:]
        for item in items {
            let key = item.sourceApp ?? String(localized: "Other", comment: "Downloads bucket for files with no recorded source app.")
            bySource[key, default: []].append(item.file)
        }
        let categories = bySource.map { source, files -> ManagerCategory in
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            return ManagerCategory(
                id: "downloads.\(source)",
                title: source,
                systemImage: "arrow.down.circle.fill",
                tint: .green,
                items: files.sorted { $0.size > $1.size }.map(item(for:)),
                totalSize: total,
                totalSizeText: ManagerByteText.string(total)
            )
        }
        .sorted { ($0.totalSize ?? 0) > ($1.totalSize ?? 0) }
        return ManagerSection(
            id: "downloads",
            title: String(localized: "Downloads", comment: "Downloads review section title."),
            categories: categories
        )
    }

    /// One selectable leaf row for a scanned file, showing its real Finder icon.
    nonisolated private static func item(for file: ScannedFile) -> ManagerItem {
        ManagerItem(
            id: file.url.path,
            title: file.url.lastPathComponent,
            subtitle: file.url.deletingLastPathComponent().path,
            size: file.size,
            sizeText: ManagerByteText.string(file.size),
            systemImage: "doc.fill",
            tint: .secondary,
            usesFileIcon: true
        )
    }
}
