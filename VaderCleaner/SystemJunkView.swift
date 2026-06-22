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
    /// at the start of every scan. Both a card's "Review" and "Review All Junk"
    /// open the same full manager.
    @State private var showingManager = false

    /// Path → file lookup the manager's selection callbacks read. Built off the
    /// main actor inside the manager's `buildSections` (so a huge scan never
    /// does O(N) work on the main thread) and read on the main actor afterward.
    @State private var lookups = CleanupReviewLookups()

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
                tiles: CleanupGroupTile.tiles(from: result),
                onReview: { _ in showingManager = true },
                onClean: { group in
                    Task { await viewModel.clean(categories: Set(group.categories)) }
                },
                onReviewAll: { showingManager = true },
                onStartOver: viewModel.scanAgain
            )
        }
    }

    /// The shared three-pane Cleanup Manager (sections → categories → files),
    /// wired to the view model's per-file selection. Both Review and Review All
    /// Junk open the full manager; the "Clean Up" footer removes the current
    /// selection. The id→file lookup is built off the main actor inside
    /// `buildSections` so opening over a huge scan never blocks the UI.
    private func managerScreen(result: ScanResult) -> some View {
        let lookups = self.lookups
        let items = result.items
        let itemsByCategory = result.itemsByCategory
        let sizeByCategory = result.sizeByCategory
        return SmartScanReviewManager(
            title: String(
                localized: "Cleanup Manager",
                comment: "Title on the standalone Cleanup section's Review screen."
            ),
            buildSections: {
                lookups.filesByID = Dictionary(
                    items.map { ($0.url.path, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let sections = CleanupManagerModel.build(
                    itemsByCategory: itemsByCategory,
                    sizeByCategory: sizeByCategory,
                    includeEmptySections: true,
                    hierarchical: true
                )
                // Index every row (folders + their children) → the leaf file
                // paths it covers, so a folder row's checkbox can select all of
                // its descendants. Built here, off the main actor.
                var pathsByID: [String: [String]] = [:]
                func index(_ rows: [ManagerItem]) {
                    for row in rows {
                        pathsByID[row.id] = row.selectionPaths.isEmpty ? [row.id] : row.selectionPaths
                        index(row.children)
                    }
                }
                for section in sections { for category in section.categories { index(category.items) } }
                lookups.pathsByID = pathsByID
                return sections
            },
            isSelected: { id in
                let paths = lookups.pathsByID[id] ?? [id]
                return !paths.isEmpty && paths.allSatisfy { lookups.filesByID[$0].map(viewModel.isSelected) ?? false }
            },
            onToggle: { id in
                let paths = lookups.pathsByID[id] ?? [id]
                // Whole-folder toggle: if every descendant is selected, clear
                // them; otherwise select them all.
                let target = !paths.allSatisfy { lookups.filesByID[$0].map(viewModel.isSelected) ?? false }
                for path in paths {
                    guard let file = lookups.filesByID[path] else { continue }
                    if viewModel.isSelected(file) != target { viewModel.toggleSelection(file) }
                }
            },
            onSetCategory: { category, selected in
                for item in category.items {
                    for path in (item.selectionPaths.isEmpty ? [item.id] : item.selectionPaths) {
                        guard let file = lookups.filesByID[path] else { continue }
                        if viewModel.isSelected(file) != selected { viewModel.toggleSelection(file) }
                    }
                }
            },
            categorySelectedBytes: { category in
                guard let scanCategory = ScanCategory(rawValue: category.id) else { return nil }
                let files = itemsByCategory[scanCategory] ?? []
                return files.reduce(Int64(0)) { $0 + (viewModel.isSelected($1) ? $1.size : 0) }
            },
            onBack: { showingManager = false },
            accessibilityPrefix: "system-junk.review",
            lightSurface: true,
            showsSparkle: true,
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

    /// Magenta accent for the Cleanup Manager card.
    private static let managerAccent = Color(red: 0.81, green: 0.10, blue: 0.55)

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

/// Holds the path → file lookup the Cleanup Manager's selection callbacks read.
/// Built once on the manager's background `buildSections` pass (so nothing O(N)
/// runs on the main thread) and read on the main actor afterward; the manager
/// only renders interactive rows once that build has finished, so there is no
/// race. Mirrors `SmartScanJunkReview`'s lookups holder.
private final class CleanupReviewLookups: @unchecked Sendable {
    /// Leaf file path → scanned file.
    var filesByID: [String: ScannedFile] = [:]
    /// Row id (folder or file) → the leaf file paths it covers, for aggregate
    /// folder-row selection.
    var pathsByID: [String: [String]] = [:]
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
