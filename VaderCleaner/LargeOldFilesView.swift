// LargeOldFilesView.swift
// Large & Old Files feature view — orchestrates scan phases, sorting, notifications, and delete confirmations.

import SwiftUI

/// Detail view shown when the user selects "Large & Old Files" in the
/// sidebar. The parent owns feature state and destructive coordination while
/// dedicated subviews render each phase, the table, rows, and footer.
struct LargeOldFilesView: View {

    @Bindable private var viewModel: LargeOldFilesViewModel
    @State private var fileIconCache = FileIconCache()
    @Environment(NotificationThresholdMonitor.self) private var notificationMonitor
    @Environment(ExclusionsStore.self) private var exclusions
    @Environment(AppState.self) private var appState

    /// Drives the "Are you sure?" alert before destructive actions. Held on
    /// the view rather than the VM so the confirmation copy can reference
    /// the current selection without forcing the VM to know about UI formatting.
    @State private var pendingDeletion: PendingDeletion?

    /// Latches once per scan so we don't fire the notification hook on every
    /// re-render of the same `.results` phase.
    @State private var notifiedForCurrentScan = false

    /// What the user drilled into from the dashboard, or `nil` for the grid.
    /// Held on the view (not the VM) because it is pure navigation state for the
    /// results surface — the same place `ApplicationsView` keeps its `detail`
    /// selection. Reset to the dashboard at the start of every scan.
    @State private var reviewing: ReviewTarget?

    /// A drill-down destination: the complete list, or one category's slice.
    private enum ReviewTarget: Equatable {
        case all
        case category(LargeOldFilesCategory)

        /// Title shown in the review screen's Back bar.
        var title: String {
            switch self {
            case .all:
                return String(
                    localized: "All Files",
                    comment: "Back-bar title for the complete, unfiltered Large & Old Files list."
                )
            case .category(let category):
                return category.title
            }
        }
    }

    init(viewModel: LargeOldFilesViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.largeOldFiles.title)
            .alert(
                deletionAlertTitle,
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { presented in
                        if !presented { pendingDeletion = nil }
                    }
                ),
                presenting: pendingDeletion
            ) { deletion in
                Button("Delete", role: .destructive) {
                    Task { await viewModel.delete(urls: deletion.urls) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { deletion in
                Text(deletionAlertMessage(for: deletion))
            }
            .onChange(of: viewModel.phase) { _, newPhase in
                handlePhaseChange(newPhase)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            // Unreachable: ContentView shows the unified SectionIntroView
            // while the coordinator reports `.intro` (which `.idle` maps to),
            // so the detail view is never built in this phase. The arm stays
            // only to keep the switch exhaustive over `Phase`.
            EmptyView()
        case .scanning:
            LargeOldFilesProgressState(
                label: "Scanning…",
                identifier: "large-old.scanning",
                detail: ScanProgressFormatting.itemsScanned(viewModel.scannedItemCount)
            )
        case .results:
            resultsContent
        case .empty:
            LargeOldFilesEmptyState(
                onScanAgain: viewModel.scanAgain,
                hasFullDiskAccess: appState.hasFullDiskAccess,
                onRefreshAccess: { appState.refresh() }
            )
        case .failed(let stage, let message):
            LargeOldFilesFailedState(stage: stage, message: message, onTryAgain: viewModel.scanAgain)
        }
    }

    /// The results surface: the category dashboard, or one category's filtered
    /// file list behind a Back bar. A category whose files were all deleted
    /// falls back to the dashboard so the user is never stranded on an empty
    /// review.
    @ViewBuilder
    private var resultsContent: some View {
        if let target = reviewing, !files(for: target).isEmpty {
            reviewScreen(for: target)
        } else {
            // No scroll view: the dashboard fills the detail pane and divides
            // the available height between the hero and the tile grid, like the
            // Health Monitor section.
            LargeOldFilesDashboardView(
                fileCount: viewModel.displayedFiles.count,
                oldCount: viewModel.displayedOldCount,
                totalBytes: viewModel.displayedTotalBytes,
                tiles: viewModel.displayedTiles,
                onReview: { reviewing = .category($0) },
                onViewAll: { reviewing = .all },
                onRescan: startScan
            )
        }
    }

    /// A drill-down's file list, reusing the shared results content (header +
    /// list + footer) wrapped in a Back bar that returns to the dashboard.
    private func reviewScreen(for target: ReviewTarget) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    reviewing = nil
                } label: {
                    // HStack(Image, Text) rather than Label so the control
                    // surfaces reliably in XCUITest.
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(String(
                            localized: "Back",
                            comment: "Back button returning from a Large & Old Files drill-down to the dashboard."
                        ))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("large-old.backToDashboard")
                Spacer()
                Text(target.title)
                    .font(.headline)
                Spacer()
                // Balances the leading Back button so the title stays centred.
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(16)
            Divider()
            LargeOldFilesResultsContent(
                files: files(for: target),
                oldCount: summary(for: target).oldCount,
                totalBytes: summary(for: target).totalBytes,
                sortOrder: $viewModel.sortOrder,
                totalSelectedSize: viewModel.totalSelectedSize,
                canDelete: !viewModel.selectedURLs.isEmpty,
                fileIconCache: fileIconCache,
                isSelected: viewModel.isSelected,
                onToggleSelection: viewModel.toggleSelection,
                onRescan: startScan,
                onDeleteSelected: requestDeletionForSelection,
                onShowInFinder: LargeOldFilesActions.showInFinder,
                onDeleteFile: requestDeletionForSingle,
                onAddToExclusions: { exclusions.add(path: $0.url.path) }
            )
        }
    }

    /// The files for a drill-down. `.all` is the full result set; a category is
    /// served straight from the view-model's precomputed tiles (already in the
    /// active sort order) so the review never re-runs the grouping on a render
    /// or selection toggle.
    private func files(for target: ReviewTarget) -> [ScannedFile] {
        switch target {
        case .all:
            return viewModel.displayedFiles
        case .category(let category):
            return viewModel.displayedTiles.first { $0.category == category }?.files ?? []
        }
    }

    /// Precomputed header aggregates for a drill-down — the full-set summary for
    /// `.all`, the tile's stored totals for a category — so the review header
    /// never re-scans the files on render.
    private func summary(for target: ReviewTarget) -> (oldCount: Int, totalBytes: Int64) {
        switch target {
        case .all:
            return (viewModel.displayedOldCount, viewModel.displayedTotalBytes)
        case .category(let category):
            guard let tile = viewModel.displayedTiles.first(where: { $0.category == category }) else {
                return (0, 0)
            }
            return (tile.oldCount, tile.totalBytes)
        }
    }

    private var deletionAlertTitle: String {
        let count = pendingDeletion?.count ?? 0
        let format = String(
            localized: "Delete %d items?",
            comment: "Alert title asking the user to confirm deleting one or more selected large/old files."
        )
        return String.localizedStringWithFormat(format, count)
    }

    private func deletionAlertMessage(for deletion: PendingDeletion) -> String {
        let format = String(
            localized: "%@ will be moved out of these locations. This cannot be undone.",
            comment: "Alert message explaining that the selected large/old files will be deleted."
        )
        return String.localizedStringWithFormat(format, deletion.formattedSize)
    }

    private func startScan() {
        Task { await viewModel.scan() }
    }

    private func requestDeletionForSelection() {
        let selected = viewModel.displayedFiles.filter { viewModel.isSelected($0) }
        guard !selected.isEmpty else { return }
        pendingDeletion = PendingDeletion(
            urls: selected.map(\.url),
            totalBytes: selected.reduce(Int64(0)) { $0 + $1.size }
        )
    }

    private func requestDeletionForSingle(_ file: ScannedFile) {
        pendingDeletion = PendingDeletion(
            urls: [file.url],
            totalBytes: file.size
        )
    }

    private func handlePhaseChange(_ newPhase: LargeOldFilesViewModel.Phase) {
        switch newPhase {
        case .scanning, .idle:
            notifiedForCurrentScan = false
            // A fresh scan always lands back on the dashboard grid, never a
            // stale drill-down from the previous run.
            reviewing = nil
        case .results(let files) where !notifiedForCurrentScan && !files.isEmpty:
            notifiedForCurrentScan = true
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            notificationMonitor.triggerLargeFilesFound(count: files.count, totalSize: total)
        default:
            break
        }
    }
}

/// View-local payload describing what's about to be deleted, surfaced to the
/// destructive-action alert via the `presenting:` parameter.
private struct PendingDeletion: Identifiable {
    let id = UUID()
    let urls: [URL]
    let totalBytes: Int64

    var count: Int { urls.count }

    var formattedSize: String {
        LargeOldFilesFormatting.byteFormatter.string(fromByteCount: totalBytes)
    }
}

#Preview("Idle") {
    LargeOldFilesView(viewModel: LargeOldFilesViewModel(
        scanner: { _ in [] },
        deleter: { _ in [] }
    ))
    .frame(width: 800, height: 520)
    .environment(ExclusionsStore(defaults: UserDefaults(suiteName: "preview")!))
    .environment(AppState(checker: { true }))
}
