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

    /// Whether the Cleanup Manager (the three-pane Review) is showing over the
    /// dashboard. Pure navigation state held on the view; reset to the dashboard
    /// at the start of every scan. A card's "Review" deep links to its
    /// section/category; "Review All Junk" opens at the default first one.
    @State private var showingManager = false
    /// Deep-link target for the manager when opened from a card's Review.
    @State private var managerInitialSection: String?
    @State private var managerInitialCategory: String?

    /// Persistent, prebuilt model for the Cleanup Manager. Warmed in the
    /// background as soon as a scan finishes so opening Review paints instantly,
    /// and reused across opens.
    @State private var managerStore = CleanupManagerStore()

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
                    detail: ScanProgressFormatting.itemsScanned(viewModel.scannedItemCount),
                    phrases: ScanPhrases.scanning(for: .systemJunk)
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
            // stale manager from the previous run.
            if case .scanning = newPhase { showingManager = false }
            // Warm the Cleanup Manager model in the background the moment a scan
            // (or seed) produces results, so opening Review is instant.
            if case .preview(let result) = newPhase { managerStore.load(result: result) }
        }
        .task {
            // Catch the case where results are already present on first appear
            // (e.g. seeded from a Smart Scan before this view existed).
            if case .preview(let result) = viewModel.phase { managerStore.load(result: result) }
        }
    }

    // MARK: - States

    private func progressState(label: String, identifier: String, detail: String? = nil, phrases: [String]? = nil) -> some View {
        VStack(spacing: 16) {
            ScanProgressIndicator()
            ScanningStatusView(
                phrases: phrases ?? [label],
                count: detail,
                countIdentifier: "\(identifier).count"
            )
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

    /// The results surface: the category dashboard, or the three-pane Cleanup
    /// Manager when the user taps Review / Review All Junk.
    @ViewBuilder
    private func resultsContent(result: ScanResult) -> some View {
        if showingManager {
            managerScreen(result: result)
        } else {
            // No scroll view: the dashboard fills the detail pane and divides
            // the available height between the header and the tile grid, like
            // the Large & Old Files section.
            SystemJunkDashboardView(
                totalBytes: result.totalSize,
                onReviewAll: {
                    // The full manager, default first section/category.
                    managerInitialSection = nil
                    managerInitialCategory = nil
                    showingManager = true
                },
                onStartOver: viewModel.scanAgain
            )
        }
    }

    /// The shared three-pane Cleanup Manager (sections → categories → files),
    /// served by `managerStore` so the panes paint instantly and each category's
    /// rows come from the store's (pre-built, cached) trees.
    private func managerScreen(result: ScanResult) -> some View {
        let store = self.managerStore
        let itemsByCategory = result.itemsByCategory
        return SmartScanReviewManager(
            title: String(
                localized: "Cleanup Manager",
                comment: "Title on the standalone Cleanup section's Review screen."
            ),
            // Cheap shell: sections + category sizes, no file trees.
            buildSections: { store.sections() },
            isSelected: { id in
                let paths = store.selectionPaths(forRowID: id)
                return !paths.isEmpty && paths.allSatisfy { store.file(forPath: $0).map(viewModel.isSelected) ?? false }
            },
            onToggle: { id in
                let paths = store.selectionPaths(forRowID: id)
                // Whole-folder toggle: if every descendant is selected, clear
                // them; otherwise select them all.
                let target = !paths.allSatisfy { store.file(forPath: $0).map(viewModel.isSelected) ?? false }
                for path in paths {
                    guard let file = store.file(forPath: path) else { continue }
                    if viewModel.isSelected(file) != target { viewModel.toggleSelection(file) }
                }
            },
            onSetCategory: { category, selected in
                // Operate on the whole scan category (by id), independent of
                // whether its rows are loaded yet.
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return }
                for file in itemsByCategory[scanCategory] ?? [] {
                    if viewModel.isSelected(file) != selected { viewModel.toggleSelection(file) }
                }
            },
            categorySelectedBytes: { category in
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return nil }
                let files = itemsByCategory[scanCategory] ?? []
                return files.reduce(Int64(0)) { $0 + (viewModel.isSelected($1) ? $1.size : 0) }
            },
            loadItems: { id in
                // Off-main: a cache hit (usually, thanks to the prebuild)
                // returns instantly; a miss builds that one category's tree
                // without blocking the UI.
                await Task.detached(priority: .userInitiated) { store.items(forCategoryID: id) }.value
            },
            onBack: { showingManager = false },
            accessibilityPrefix: "system-junk.review",
            lightSurface: true,
            showsSparkle: true,
            initialSectionID: managerInitialSection,
            initialCategoryID: managerInitialCategory,
            primaryActionTitle: String(
                localized: "Clean Up",
                comment: "Footer button on the Cleanup Manager that removes the selected junk."
            ),
            onPrimaryAction: { Task { await viewModel.clean() } },
            primaryActionEnabled: !viewModel.selectedURLs.isEmpty,
            selectionSummary: {
                ManagerSelectionSummary(
                    count: viewModel.selectedURLs.count,
                    bytes: viewModel.totalSelectedSize
                )
            }
        )
        // The Cleanup Manager uses a magenta accent (not the section's green)
        // to match the reference: it tints the sort/select values, chevrons,
        // selection, checkboxes, and the Clean Up button.
        .tint(Self.managerAccent)
        .environment(\.sectionAccent, Self.managerAccent)
    }

    /// Magenta accent for the Cleanup Manager card, shared with the other
    /// standalone Manager cards.
    private static let managerAccent = ManagerChrome.accent

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
