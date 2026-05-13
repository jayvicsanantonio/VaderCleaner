// LargeOldFilesView.swift
// Large & Old Files feature view — orchestrates scan phases, sorting, notifications, and delete confirmations.

import SwiftUI

/// Detail view shown when the user selects "Large & Old Files" in the
/// sidebar. The parent owns feature state and destructive coordination while
/// dedicated subviews render each phase, the table, rows, and footer.
struct LargeOldFilesView: View {

    @StateObject private var viewModel: LargeOldFilesViewModel
    @EnvironmentObject private var notificationMonitor: NotificationThresholdMonitor

    /// Drives the "Are you sure?" alert before destructive actions. Held on
    /// the view rather than the VM so the confirmation copy can reference
    /// the current selection without forcing the VM to know about UI formatting.
    @State private var pendingDeletion: PendingDeletion?

    /// Latches once per scan so we don't fire the notification hook on every
    /// re-render of the same `.results` phase.
    @State private var notifiedForCurrentScan = false

    init(viewModel: LargeOldFilesViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
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
            LargeOldFilesIdleState(onScan: startScan)
        case .scanning:
            LargeOldFilesProgressState(label: "Scanning…", identifier: "large-old.scanning")
        case .results:
            LargeOldFilesResultsContent(
                files: viewModel.displayedFiles,
                sortOrder: $viewModel.sortOrder,
                totalSelectedSize: viewModel.totalSelectedSize,
                canDelete: !viewModel.selectedURLs.isEmpty,
                isSelected: viewModel.isSelected,
                onToggleSelection: viewModel.toggleSelection,
                onRescan: startScan,
                onDeleteSelected: requestDeletionForSelection,
                onShowInFinder: LargeOldFilesActions.showInFinder,
                onDeleteFile: requestDeletionForSingle
            )
        case .empty:
            LargeOldFilesEmptyState(onScanAgain: viewModel.scanAgain)
        case .failed(let stage, let message):
            LargeOldFilesFailedState(stage: stage, message: message, onTryAgain: viewModel.scanAgain)
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
        scanner: { [] },
        deleter: { _ in [] }
    ))
    .frame(width: 800, height: 520)
}
