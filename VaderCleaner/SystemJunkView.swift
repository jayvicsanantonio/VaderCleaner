// SystemJunkView.swift
// System Junk feature view — renders the idle/scanning/preview/cleaning/complete states from SystemJunkViewModel and binds the per-category checkboxes and Clean / Re-scan / Scan Again actions.

import SwiftUI

/// Detail view shown when the user selects "System Junk" in the sidebar.
/// Each phase of `SystemJunkViewModel.Phase` maps to a dedicated subview:
///   - `.idle` — not rendered here; ContentView shows the unified intro.
///   - `.scanning` — progress spinner.
///   - `.preview` — list of categories with checkboxes plus Clean/Re-scan.
///   - `.cleaning` — progress spinner.
///   - `.complete` — "X.X freed" summary plus Scan Again.
///   - `.failed` — message plus Try Again.
///
/// Accessibility identifiers are namespaced under `system-junk.*` so UI tests
/// can drive the flow without relying on label localisation.
struct SystemJunkView: View {

    private var viewModel: SystemJunkViewModel
    @Environment(AppState.self) private var appState

    /// Shared icon cache so the review rows show each file's real type icon
    /// instead of a generic glyph. Pre-loaded off the main thread by the review
    /// content when it appears.
    @State private var fileIconCache = FileIconCache()

    /// What the user drilled into from the dashboard, or `nil` for the grid.
    /// Held on the view (not the VM) because it is pure navigation state — the
    /// same place `LargeOldFilesView` keeps its drill-down selection. Reset to
    /// the dashboard at the start of every scan.
    @State private var reviewing: ReviewTarget?

    /// A drill-down destination: the complete list, or one category's slice.
    private enum ReviewTarget: Equatable {
        case all
        case category(ScanCategory)

        /// Title shown in the review screen's Back bar.
        var title: String {
            switch self {
            case .all:
                return String(
                    localized: "All Junk Files",
                    comment: "Back-bar title for the complete, unfiltered System Junk list."
                )
            case .category(let category):
                return category.displayName
            }
        }
    }

    init(viewModel: SystemJunkViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle:
                // Unreachable: ContentView shows the unified SectionIntroView
                // while the coordinator reports `.intro` (which `.idle` maps
                // to), so the detail view is never built in this phase. The
                // arm stays only to keep the switch exhaustive over `Phase`.
                EmptyView()
            case .scanning:
                progressState(
                    label: "Scanning…",
                    identifier: "system-junk.scanning",
                    detail: ScanProgressFormatting.itemsScanned(viewModel.scannedItemCount)
                )
            case .preview(let result):
                previewState(result: result)
            case .cleaning:
                progressState(label: "Cleaning…", identifier: "system-junk.cleaning")
            case .complete(let bytes):
                completeState(bytesFreed: bytes)
            case .failed(let stage, let message):
                failedState(stage: stage, message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.systemJunk.title)
        .onChange(of: viewModel.phase) { _, newPhase in
            // A fresh scan always lands back on the dashboard grid, never a
            // stale drill-down from the previous run.
            if case .scanning = newPhase { reviewing = nil }
        }
    }

    // MARK: - States

    private func progressState(label: String, identifier: String, detail: String? = nil) -> some View {
        VStack(spacing: 16) {
            ScanProgressIndicator()
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

    @ViewBuilder
    private func previewState(result: ScanResult) -> some View {
        if result.items.isEmpty {
            // A scan that found nothing collapses to the dedicated empty
            // subview — the dashboard + disabled Clean footer reads as "you
            // did something wrong" when the truth is "nothing qualified." The
            // empty subview also carries the FDA reminder for the
            // silent-failure case.
            SystemJunkEmptyPreviewState(
                onScanAgain: viewModel.scanAgain,
                hasFullDiskAccess: appState.hasFullDiskAccess,
                onRefreshAccess: { appState.refresh() }
            )
        } else {
            resultsContent(result: result)
        }
    }

    /// The results surface: the category dashboard, or one drill-down's file
    /// list behind a Back bar. A drill-down whose files were all cleaned falls
    /// back to the dashboard so the user is never stranded on an empty review.
    @ViewBuilder
    private func resultsContent(result: ScanResult) -> some View {
        if let target = reviewing, !files(for: target, in: result).isEmpty {
            reviewScreen(for: target, in: result)
        } else {
            // No scroll view: the dashboard fills the detail pane and divides
            // the available height between the header and the tile grid, like
            // the Large & Old Files section.
            SystemJunkDashboardView(
                totalBytes: result.totalSize,
                itemCount: result.items.count,
                tiles: SystemJunkTile.tiles(from: result),
                onReview: { reviewing = .category($0) },
                onViewAll: { reviewing = .all },
                onRescan: viewModel.scanAgain
            )
        }
    }

    /// A drill-down's file list, wrapped in a Back bar that returns to the
    /// dashboard. Mirrors `LargeOldFilesView.reviewScreen`.
    private func reviewScreen(for target: ReviewTarget, in result: ScanResult) -> some View {
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
                            comment: "Back button returning from a System Junk drill-down to the dashboard."
                        ))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("system-junk.backToDashboard")
                Spacer()
                Text(target.title)
                    .font(.headline)
                Spacer()
                // Balances the leading Back button so the title stays centred.
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(16)
            Divider()
            SystemJunkReviewContent(
                files: files(for: target, in: result),
                totalBytes: totalBytes(for: target, in: result),
                totalSelectedSize: viewModel.totalSelectedSize,
                canClean: !viewModel.selectedURLs.isEmpty,
                fileIconCache: fileIconCache,
                isSelected: viewModel.isSelected,
                onToggleSelection: viewModel.toggleSelection,
                onRescan: viewModel.scanAgain,
                onClean: { Task { await viewModel.clean() } }
            )
        }
    }

    /// The files for a drill-down. `.all` is the full result set; a category is
    /// served straight from the result's per-category grouping.
    private func files(for target: ReviewTarget, in result: ScanResult) -> [ScannedFile] {
        switch target {
        case .all:
            return result.items
        case .category(let category):
            return result.itemsByCategory[category] ?? []
        }
    }

    /// Summed size for a drill-down, read from the result's precomputed totals
    /// so the header never re-sums the files on render.
    private func totalBytes(for target: ReviewTarget, in result: ScanResult) -> Int64 {
        switch target {
        case .all:
            return result.totalSize
        case .category(let category):
            return result.sizeByCategory[category] ?? 0
        }
    }

    private func completeState(bytesFreed: Int64) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(SystemJunkView.byteFormatter.string(fromByteCount: bytesFreed) + " freed")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("system-junk.bytesFreed")
            Button("Scan Again") {
                viewModel.scanAgain()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("system-junk.scanAgain")
        }
        .padding()
    }

    private func failedState(stage: SystemJunkViewModel.FailureStage, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(stage == .scanning ? "Couldn't complete the scan" : "Couldn't finish cleaning")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .accessibilityIdentifier("system-junk.errorMessage")
            Button("Try Again") {
                viewModel.scanAgain()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("system-junk.tryAgain")
        }
        .padding()
    }

    // MARK: - Formatter

    /// Shared `ByteCountFormatter` for the "freed" summary on the complete
    /// state. Kept as a static so the allocation does not happen inside the
    /// view body's expression evaluator on every redraw.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

// MARK: - Subviews

/// Empty-result variant of the preview state. Surfaces when a scan returns
/// zero items — without it, the user would land on the regular preview list
/// with a disabled Clean button, reading as "I did something wrong" when the
/// truth is "nothing qualified or FDA blocked the reads." The inline FDA
/// reminder card surfaces under the CTA whenever access is missing, so the
/// silent-failure case is always explained.
struct SystemJunkEmptyPreviewState: View {
    let onScanAgain: () -> Void
    /// Current Full Disk Access state. Drives whether the inline reminder
    /// appears under the "Scan Again" CTA.
    let hasFullDiskAccess: Bool
    /// Re-runs the FDA check, wired to `AppState.refresh()` so the card can
    /// fade out the moment the user grants access in System Settings.
    let onRefreshAccess: () -> Void

    /// Pure predicate so the gate is unit-testable without rendering. The
    /// per-section "this scan needs FDA" decision lives in
    /// `NavigationSection.requiresFullDiskAccess`; here it is unconditional
    /// because System Junk always requires FDA to read /Library/Caches and
    /// /Library/Logs.
    var shouldShowFullDiskAccessReminder: Bool { !hasFullDiskAccess }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Nothing to clean up")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("system-junk.emptyTitle")
            Text("No junk caches, logs, or mail attachments were found this time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan Again", action: onScanAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("system-junk.emptyScanAgain")

            if shouldShowFullDiskAccessReminder {
                FullDiskAccessPromptCard(
                    accent: .green,
                    onRecheck: onRefreshAccess
                )
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .animation(.smooth(duration: 0.4), value: hasFullDiskAccess)
    }
}

#Preview("Idle") {
    SystemJunkView(viewModel: SystemJunkViewModel(
        scanner: { _ in ScanResult(items: []) },
        deleter: { _ in 0 }
    ))
    .frame(width: 700, height: 480)
    .environment(AppState(checker: { true }))
}
