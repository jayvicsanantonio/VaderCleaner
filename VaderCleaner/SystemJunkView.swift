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
    }

    // MARK: - States

    private func progressState(label: String, identifier: String, detail: String? = nil) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
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
            // subview — the regular preview list + disabled Clean footer
            // reads as "you did something wrong" when the truth is "nothing
            // qualified." The empty subview also carries the FDA reminder
            // for the silent-failure case.
            SystemJunkEmptyPreviewState(
                onScanAgain: viewModel.scanAgain,
                hasFullDiskAccess: appState.hasFullDiskAccess,
                onRefreshAccess: { appState.refresh() }
            )
        } else {
            VStack(spacing: 0) {
                previewList(result: result)
                Divider()
                previewFooter
            }
        }
    }

    private func previewList(result: ScanResult) -> some View {
        let categories = ScanCategory.allCases.filter { result.itemsByCategory[$0] != nil }
        return List {
            ForEach(categories, id: \.self) { category in
                CategoryRow(
                    category: category,
                    itemCount: result.itemsByCategory[category]?.count ?? 0,
                    sizeBytes: result.sizeByCategory[category] ?? 0,
                    isChecked: Binding(
                        get: { viewModel.isChecked(category) },
                        set: { _ in viewModel.toggle(category) }
                    )
                )
                .accessibilityIdentifier("system-junk.row.\(category.rawValue)")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var previewFooter: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.formattedTotalSelectedSize)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("system-junk.totalSelected")
            }
            Spacer()
            Button("Re-scan") {
                viewModel.scanAgain()
            }
            .accessibilityIdentifier("system-junk.rescan")
            Button("Clean") {
                Task { await viewModel.clean() }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.vaderProminent)
            .disabled(viewModel.totalSelectedSize == 0)
            .accessibilityIdentifier("system-junk.clean")
        }
        .padding(16)
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
    /// state and every per-category row. `fileprivate` (not `private`) so
    /// the `CategoryRow` subview below can reuse the same instance instead
    /// of allocating its own. Kept as a static so the allocation does not
    /// happen inside the view body's expression evaluator on every redraw.
    fileprivate static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

// MARK: - Subviews

/// Single row in the preview list. Bound to a checkbox `Toggle` whose
/// `Binding` drives `SystemJunkViewModel.toggle(_:)` on changes.
private struct CategoryRow: View {
    let category: ScanCategory
    let itemCount: Int
    let sizeBytes: Int64
    @Binding var isChecked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                    .font(.body.weight(.medium))
                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(SystemJunkView.byteFormatter.string(fromByteCount: sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

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
