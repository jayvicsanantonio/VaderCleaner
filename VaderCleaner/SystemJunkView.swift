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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the Cleanup Manager (the three-pane Review) is showing over the
    /// dashboard. Pure navigation state held on the view; reset to the dashboard
    /// at the start of every scan. A card's "Review" deep links to its
    /// section/category; "Review All Junk" opens at the default first one.
    @State private var showingManager = false
    /// Deep-link target for the manager when opened from a card's Review.
    @State private var managerInitialSection: String?
    @State private var managerInitialCategory: String?
    /// Where the manager zoom anchors: the button that opened it, resolved
    /// by `openManager`. Also the point Back zooms the manager back into.
    @State private var managerAnchor: UnitPoint = .center
    /// The transition host's frame in global space, for mapping the opening
    /// click to `managerAnchor`.
    @State private var paneFrame: CGRect = .zero
    /// The title-bar safe-area inset the transition host permanently claims;
    /// handed back to the dashboard as top padding so only the manager
    /// extends under the title bar.
    @State private var paneTopInset: CGFloat = 0

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
        }
    }

    // MARK: - States

    private func progressState(label: String, identifier: String, detail: String? = nil, phrases: [String]? = nil) -> some View {
        VStack(spacing: 28) {
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
    /// Manager when the user taps Review / Review All Junk. The two surfaces
    /// exchange inside `ManagerPresentationHost` (a stable transition host)
    /// with the shared manager motion: the manager zooms up from the button
    /// that opened it over the receding dashboard, and zooms back into it on
    /// Back — after which it stays mounted (hidden), so reopening restores
    /// the already-built panes instantly instead of rebuilding them.
    private func resultsContent(result: ScanResult) -> some View {
        ManagerPresentationHost(
            isPresented: showingManager,
            anchor: managerAnchor,
            reduceMotion: reduceMotion,
            dashboardTopInset: paneTopInset
        ) {
            dashboard(result: result)
        } manager: {
            managerScreen(result: result)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame = $0 })
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { paneTopInset = $0 })
    }

    /// Anchors the zoom to the button (or failing that, the click) being
    /// handled, then raises the manager.
    private func openManager() {
        managerAnchor = TriggerAnchor.resolve(in: paneFrame)
        showingManager = true
    }

    /// The post-scan category dashboard grid.
    private func dashboard(result: ScanResult) -> some View {
        // No scroll view: the dashboard fills the detail pane and divides
        // the available height between the header and the tile grid, like
        // the Large & Old Files section.
        SystemJunkDashboardView(
            totalBytes: result.totalSize,
            tiles: CleanupDashboardTile.recommended(from: result),
            accent: NavigationSection.systemJunk.theme.accent,
            onReview: { group in
                // The zoom anchor and deep-link state resolve synchronously in
                // the click (the anchor reads the press/click event), before
                // the selection walk hops off the main actor.
                managerAnchor = TriggerAnchor.resolve(in: paneFrame)
                // Deep link: open the manager at this card's section and the
                // sub-category the card maps to.
                let category = group.managerCategory
                managerInitialSection = category.flatMap(CleanupManagerModel.sectionID(containing:))
                    ?? CleanupManagerModel.groups.first?.id
                managerInitialCategory = category?.rawValue
                Task {
                    // Pre-select this card's whole group so the right pane opens
                    // all-checked and the selected total matches the card's size.
                    // The manager raises only once the selection has landed, so
                    // it never opens on a half-applied selection.
                    await viewModel.selectOnly(categories: Set(group.categories))
                    showingManager = true
                }
            },
            onClean: { group in
                Task { await viewModel.clean(categories: Set(group.categories)) }
            },
            onReviewAll: {
                // The full manager, default first section/category.
                managerInitialSection = nil
                managerInitialCategory = nil
                openManager()
            },
            onStartOver: viewModel.scanAgain
        )
    }

    /// The shared three-pane Cleanup Manager (sections → categories → files),
    /// served by the view-model's `managerStore` so the panes paint instantly
    /// and each category's rows come from the store's (pre-built, cached)
    /// trees.
    private func managerScreen(result: ScanResult) -> some View {
        let store = viewModel.managerStore
        let itemsByCategory = result.itemsByCategory
        return SmartScanReviewManager(
            title: String(
                localized: "Cleanup Manager",
                comment: "Title on the standalone Cleanup section's Review screen."
            ),
            // Cheap shell: sections + category sizes, no file trees.
            buildSections: { store.sections() },
            isSelected: { id in
                // Checked when every file beneath the row is selected. The walk
                // runs in place under one store lock and short-circuits on the
                // first unselected file, never materializing the subtree's file
                // array. (The manager's per-category fast path answers the
                // common all/none states before this runs at all.)
                store.allFilesSelected(forRowID: id) { viewModel.isSelected($0) }
            },
            onToggle: { id in
                // Whole-folder toggle in one batched pass: gather the row's files
                // under a single lock, then flip them together so a folder over
                // tens of thousands of files fires one UI update, not one per
                // file.
                viewModel.toggleSelection(store.files(forRowID: id))
            },
            onSetCategory: { category, selected in
                // Operate on the whole scan category (by id), independent of
                // whether its rows are loaded yet — one batched selection pass.
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return }
                viewModel.setSelection(itemsByCategory[scanCategory] ?? [], selected: selected)
            },
            categorySelectedBytes: { category in
                // O(1) read of the view-model's incrementally-maintained
                // per-category total, instead of reducing over every file in
                // the category on every render — the walk that beachballed
                // switching categories on large scans.
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return nil }
                return viewModel.selectedBytes(in: scanCategory)
            },
            categorySelectionTally: { category in
                // O(1) None/All/Some for the bulk-select menu: the view model's
                // incrementally-maintained per-category selected count against
                // the scan's file count for that category — instead of the
                // folder-aggregate scan that walked every file (with a lock per
                // path) on each render and delayed the checkbox repaint.
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return nil }
                let total = itemsByCategory[scanCategory]?.count ?? 0
                return (selected: viewModel.selectedCount(in: scanCategory), total: total)
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
            // The host keeps this manager alive across Back; flipping this
            // re-aims the panes at the deep-link target on each open.
            isPresented: showingManager,
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
                .transition(.opacity)
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
