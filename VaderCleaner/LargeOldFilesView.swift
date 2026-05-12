// LargeOldFilesView.swift
// Large & Old Files feature view — renders the idle/scanning/results/empty/failed states from LargeOldFilesViewModel, the sortable Table with per-row checkboxes, and the Delete-Selected confirmation alert.

import SwiftUI
import AppKit

/// Detail view shown when the user selects "Large & Old Files" in the
/// sidebar. Each phase of `LargeOldFilesViewModel.Phase` maps to a dedicated
/// subview:
///   - `.idle`     — centered Scan call-to-action.
///   - `.scanning` — progress spinner.
///   - `.results`  — sortable table with per-row checkboxes plus the footer.
///   - `.empty`    — "Nothing matched" copy with Scan Again.
///   - `.failed`   — message plus Try Again.
///
/// Accessibility identifiers are namespaced under `large-old.*` so future UI
/// tests can drive the flow without relying on label localisation.
struct LargeOldFilesView: View {

    @ObservedObject private var viewModel: LargeOldFilesViewModel
    @EnvironmentObject private var notificationMonitor: NotificationThresholdMonitor

    /// Drives the "Are you sure?" alert before destructive actions. Held on
    /// the view rather than the VM so the confirmation copy can reference
    /// the *current* selection without forcing the VM to know about UI
    /// formatting.
    @State private var pendingDeletion: PendingDeletion?

    /// Latches once per scan so we don't fire the
    /// `triggerLargeFilesFound` hook on every re-render of the same
    /// `.results` phase. Reset on `.scan()` and `.scanAgain()` paths via
    /// the `.onChange` handler below.
    @State private var notifiedForCurrentScan = false

    init(viewModel: LargeOldFilesViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle:
                idleState
            case .scanning:
                progressState(label: "Scanning…", identifier: "large-old.scanning")
            case .results(let files):
                resultsState(files: files)
            case .empty:
                emptyState
            case .failed(let stage, let message):
                failedState(stage: stage, message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.largeOldFiles.title)
        // The classic `Alert(title:message:primaryButton:secondaryButton:)`
        // initializer was deprecated in macOS 12 in favor of the role-aware
        // `.alert(_:isPresented:presenting:actions:message:)` modifier. We
        // bridge the optional `pendingDeletion` payload through a derived
        // `Bool` binding because the new modifier separates "show me" and
        // "what to show" — clearing the binding still also clears the
        // payload so the next request rebuilds the alert from scratch.
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
            Text("\(deletion.formattedSize) will be moved out of these locations. This cannot be undone.")
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
    }

    // MARK: - States

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Large & Old Files")
                .font(.title2.weight(.semibold))
            Text("Scan your home folder for files larger than 50 MB or not accessed in the past six months.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan") {
                Task { await viewModel.scan() }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("large-old.scan")
        }
        .padding()
    }

    private func progressState(label: String, identifier: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityIdentifier(identifier)
    }

    private func resultsState(files: [ScannedFile]) -> some View {
        // We bind the table to `viewModel.displayedFiles` rather than the
        // `files` payload off the phase so re-sorting and deletes flow
        // through one stable source of truth.
        VStack(spacing: 0) {
            resultsTable
            Divider()
            resultsFooter
        }
    }

    private var resultsTable: some View {
        Table(viewModel.displayedFiles) {
            TableColumn("") { file in
                Toggle("", isOn: Binding(
                    get: { viewModel.isSelected(file) },
                    set: { _ in viewModel.toggleSelection(file) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityIdentifier("large-old.row.\(file.url.path).checkbox")
            }
            .width(28)

            TableColumn("Name") { file in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(file.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contextMenu { rowContextMenu(for: file) }
            }

            TableColumn("Size") { file in
                Text(Self.byteFormatter.string(fromByteCount: file.size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Last Accessed") { file in
                Text(formattedAccessDate(file.lastAccessDate))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140, max: 180)

            TableColumn("Path") { file in
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.url.path)
            }
        }
        .accessibilityIdentifier("large-old.table")
        .toolbar { sortToolbar }
    }

    private var sortToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Sort by", selection: $viewModel.sortOrder) {
                Text("Largest first").tag(LargeOldFilesViewModel.SortOrder.sizeDescending)
                Text("Smallest first").tag(LargeOldFilesViewModel.SortOrder.sizeAscending)
                Text("Oldest first").tag(LargeOldFilesViewModel.SortOrder.dateAscending)
                Text("Newest first").tag(LargeOldFilesViewModel.SortOrder.dateDescending)
                Text("Name (A–Z)").tag(LargeOldFilesViewModel.SortOrder.nameAscending)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("large-old.sort")
        }
    }

    private var resultsFooter: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Self.byteFormatter.string(fromByteCount: viewModel.totalSelectedSize))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("large-old.totalSelected")
            }
            Spacer()
            Button("Re-scan") {
                Task { await viewModel.scan() }
            }
            .accessibilityIdentifier("large-old.rescan")
            Button("Delete Selected") {
                requestDeletionForSelection()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedURLs.isEmpty)
            .accessibilityIdentifier("large-old.delete")
        }
        .padding(16)
    }

    private var emptyState: some View {
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
            Button("Scan Again") {
                viewModel.scanAgain()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("large-old.scanAgain")
        }
        .padding()
    }

    private func failedState(stage: LargeOldFilesViewModel.FailureStage, message: String) -> some View {
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
            Button("Try Again") {
                viewModel.scanAgain()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("large-old.tryAgain")
        }
        .padding()
    }

    // MARK: - Context menu

    @ViewBuilder
    private func rowContextMenu(for file: ScannedFile) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        }
        Divider()
        Button("Delete", role: .destructive) {
            requestDeletionForSingle(file)
        }
    }

    // MARK: - Delete confirmation

    private func requestDeletionForSelection() {
        let selected = viewModel.displayedFiles.filter { viewModel.isSelected($0) }
        guard !selected.isEmpty else { return }
        pendingDeletion = PendingDeletion(
            urls: selected.map(\.url),
            totalBytes: selected.reduce(Int64(0)) { $0 + $1.size }
        )
    }

    private func requestDeletionForSingle(_ file: ScannedFile) {
        // Right-click "Delete" targets only the single right-clicked row,
        // not the broader selection — that matches Finder's behavior and
        // avoids the user accidentally nuking unrelated checked rows.
        pendingDeletion = PendingDeletion(
            urls: [file.url],
            totalBytes: file.size
        )
    }

    /// Run a phase change through the notification dispatcher exactly once
    /// per scan, when a `.results` lands non-empty. The cooldown gate on
    /// `NotificationThresholdMonitor` still applies — multiple scans in
    /// quick succession won't spam the user.
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

    // MARK: - Formatting

    /// Renders an access date the way Finder labels its "Last opened" column —
    /// medium-style date, no time, abbreviated for table density.
    private func formattedAccessDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    /// Title for the destructive-action alert. Computed from
    /// `pendingDeletion` because the modern `.alert(_:isPresented:...)`
    /// modifier wants a static title at modifier-call time, but the count
    /// is dynamic. Re-evaluating per render is cheap and the alert is only
    /// rendered while `pendingDeletion` is non-nil, so the fallback `0`
    /// branch is unreachable in practice.
    private var deletionAlertTitle: String {
        let count = pendingDeletion?.count ?? 0
        return "Delete \(count) item\(count == 1 ? "" : "s")?"
    }

    fileprivate static let byteFormatter: ByteCountFormatter = {
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
}

// MARK: - Pending deletion

/// View-local payload describing what's about to be deleted, surfaced
/// to the destructive-action alert via the `presenting:` parameter of
/// `.alert(_:isPresented:presenting:actions:message:)`. `Identifiable`
/// is no longer required by the modifier we use, but we keep the fresh-
/// UUID `id` because `Alert.actions(_:)` re-renders per identity change
/// and a fresh UUID guarantees a fresh closure capture for each pending
/// request.
private struct PendingDeletion: Identifiable {
    let id = UUID()
    let urls: [URL]
    let totalBytes: Int64

    var count: Int { urls.count }

    var formattedSize: String {
        LargeOldFilesView.byteFormatter.string(fromByteCount: totalBytes)
    }
}

// MARK: - ScannedFile + Identifiable

/// `Table` requires its data to be `Identifiable`. `ScannedFile.url` is
/// guaranteed unique within a single scan (the `FileScanner` walks each
/// path once and skips symlinks), so the URL is a stable identity. Held in
/// this file rather than on the type so the model layer doesn't pull in a
/// SwiftUI dependency.
extension ScannedFile: Identifiable {
    var id: URL { url }
}

#Preview("Idle") {
    LargeOldFilesView(viewModel: LargeOldFilesViewModel(
        scanner: { [] },
        deleter: { _ in [] }
    ))
    .frame(width: 800, height: 520)
}
