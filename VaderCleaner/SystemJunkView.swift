// SystemJunkView.swift
// System Junk feature view — renders the idle/scanning/preview/cleaning/complete states from SystemJunkViewModel and binds the per-category checkboxes and Clean / Re-scan / Scan Again actions.

import SwiftUI

/// Detail view shown when the user selects "System Junk" in the sidebar.
/// Each phase of `SystemJunkViewModel.Phase` maps to a dedicated subview:
///   - `.idle` — centered Scan call-to-action.
///   - `.scanning` — progress spinner.
///   - `.preview` — list of categories with checkboxes plus Clean/Re-scan.
///   - `.cleaning` — progress spinner.
///   - `.complete` — "X.X freed" summary plus Scan Again.
///   - `.failed` — message plus Try Again.
///
/// Accessibility identifiers are namespaced under `system-junk.*` so UI tests
/// can drive the flow without relying on label localisation.
struct SystemJunkView: View {

    @StateObject private var viewModel: SystemJunkViewModel

    init(viewModel: SystemJunkViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle:
                idleState
            case .scanning:
                progressState(label: "Scanning…", identifier: "system-junk.scanning")
            case .preview(let result):
                previewState(result: result)
            case .cleaning:
                progressState(label: "Cleaning…", identifier: "system-junk.cleaning")
            case .complete(let bytes):
                completeState(bytesFreed: bytes)
            case .failed(let message):
                failedState(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.systemJunk.title)
    }

    // MARK: - States

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("System Junk")
                .font(.title2.weight(.semibold))
            Text("Scan caches, logs, mail attachments, iOS backups, trash, and stale language files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Scan") {
                Task { await viewModel.scan() }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("system-junk.scan")
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

    private func previewState(result: ScanResult) -> some View {
        VStack(spacing: 0) {
            previewList(result: result)
            Divider()
            previewFooter
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
            .buttonStyle(.borderedProminent)
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

    private func failedState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Couldn't complete the scan")
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
    /// state. Kept on the view so the formatter allocation does not happen
    /// inside the view body's expression evaluator on every redraw.
    private static let byteFormatter: ByteCountFormatter = {
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

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()

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
            Text(Self.byteFormatter.string(fromByteCount: sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview("Idle") {
    SystemJunkView(viewModel: SystemJunkViewModel(
        scanner: { ScanResult(items: []) },
        deleter: { _ in 0 }
    ))
    .frame(width: 700, height: 480)
}
