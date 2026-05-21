// LargeOldFilesViewSubviews.swift
// Dedicated subviews for LargeOldFilesView state screens, table, rows, and footer.

import SwiftUI
import AppKit

enum LargeOldFilesFormatting {
    static let byteFormatter: ByteCountFormatter = {
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

    static func accessDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    static func selectionLabel(for file: ScannedFile) -> String {
        let format = String(
            localized: "Select %@",
            comment: "Accessibility label for selecting a file in the Large & Old Files table."
        )
        return String.localizedStringWithFormat(format, file.url.lastPathComponent)
    }
}

enum LargeOldFilesActions {
    static func showInFinder(_ file: ScannedFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }
}

struct LargeOldFilesProgressState: View {
    let label: String
    let identifier: String

    var body: some View {
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
}

struct LargeOldFilesResultsContent: View {
    let files: [ScannedFile]
    @Binding var sortOrder: LargeOldFilesViewModel.SortOrder
    let totalSelectedSize: Int64
    let canDelete: Bool
    @ObservedObject var fileIconCache: FileIconCache
    let isSelected: (ScannedFile) -> Bool
    let onToggleSelection: (ScannedFile) -> Void
    let onRescan: () -> Void
    let onDeleteSelected: () -> Void
    let onShowInFinder: (ScannedFile) -> Void
    let onDeleteFile: (ScannedFile) -> Void
    let onAddToExclusions: (ScannedFile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            LargeOldFilesTable(
                files: files,
                sortOrder: $sortOrder,
                fileIconCache: fileIconCache,
                isSelected: isSelected,
                onToggleSelection: onToggleSelection,
                onShowInFinder: onShowInFinder,
                onDeleteFile: onDeleteFile,
                onAddToExclusions: onAddToExclusions
            )
            Divider()
            LargeOldFilesFooter(
                totalSelectedSize: totalSelectedSize,
                canDelete: canDelete,
                onRescan: onRescan,
                onDeleteSelected: onDeleteSelected
            )
        }
        .task(id: files) {
            await fileIconCache.preloadIcons(for: files.map(\.url))
        }
    }
}

struct LargeOldFilesTable: View {
    let files: [ScannedFile]
    @Binding var sortOrder: LargeOldFilesViewModel.SortOrder
    @ObservedObject var fileIconCache: FileIconCache
    let isSelected: (ScannedFile) -> Bool
    let onToggleSelection: (ScannedFile) -> Void
    let onShowInFinder: (ScannedFile) -> Void
    let onDeleteFile: (ScannedFile) -> Void
    let onAddToExclusions: (ScannedFile) -> Void

    var body: some View {
        Table(files) {
            TableColumn("") { file in
                Toggle("", isOn: Binding(
                    get: { isSelected(file) },
                    set: { _ in onToggleSelection(file) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(LargeOldFilesFormatting.selectionLabel(for: file)))
                .accessibilityIdentifier("large-old.row.\(file.url.path).checkbox")
            }
            .width(28)

            TableColumn(String(
                localized: "Name",
                comment: "Column title for the file name column in the Large & Old Files table."
            )) { file in
                LargeOldFilesRowNameCell(
                    file: file,
                    fileIconCache: fileIconCache,
                    onShowInFinder: onShowInFinder,
                    onDelete: onDeleteFile,
                    onAddToExclusions: onAddToExclusions
                )
            }

            TableColumn(String(
                localized: "Size",
                comment: "Column title for the file size column in the Large & Old Files table."
            )) { file in
                Text(LargeOldFilesFormatting.byteFormatter.string(fromByteCount: file.size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn(String(
                localized: "Last Accessed",
                comment: "Column title for the last accessed date column in the Large & Old Files table."
            )) { file in
                Text(LargeOldFilesFormatting.accessDate(file.lastAccessDate))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140, max: 180)

            TableColumn(String(
                localized: "Path",
                comment: "Column title for the file path column in the Large & Old Files table."
            )) { file in
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.url.path)
            }
        }
        .accessibilityIdentifier("large-old.table")
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(String(
                    localized: "Sort by",
                    comment: "Label for the Large & Old Files sort menu."
                ), selection: $sortOrder) {
                    Text(String(
                        localized: "Largest first",
                        comment: "Sort option that orders files from largest to smallest."
                    )).tag(LargeOldFilesViewModel.SortOrder.sizeDescending)
                    Text(String(
                        localized: "Smallest first",
                        comment: "Sort option that orders files from smallest to largest."
                    )).tag(LargeOldFilesViewModel.SortOrder.sizeAscending)
                    Text(String(
                        localized: "Oldest first",
                        comment: "Sort option that orders files by oldest access date first."
                    )).tag(LargeOldFilesViewModel.SortOrder.dateAscending)
                    Text(String(
                        localized: "Newest first",
                        comment: "Sort option that orders files by newest access date first."
                    )).tag(LargeOldFilesViewModel.SortOrder.dateDescending)
                    Text(String(
                        localized: "Name (A–Z)",
                        comment: "Sort option that orders files alphabetically by name."
                    )).tag(LargeOldFilesViewModel.SortOrder.nameAscending)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("large-old.sort")
            }
        }
    }
}

struct LargeOldFilesRowNameCell: View {
    let file: ScannedFile
    @ObservedObject var fileIconCache: FileIconCache
    let onShowInFinder: (ScannedFile) -> Void
    let onDelete: (ScannedFile) -> Void
    let onAddToExclusions: (ScannedFile) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: fileIconCache.cachedIcon(for: file.url))
                .resizable()
                .frame(width: 16, height: 16)
            Text(file.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            Button("Show in Finder") {
                onShowInFinder(file)
            }
            Button(String(
                localized: "Add to Exclusions",
                comment: "Context menu item that adds the selected file to the scan-exclusions list."
            )) {
                onAddToExclusions(file)
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete(file)
            }
        }
    }
}

struct LargeOldFilesFooter: View {
    let totalSelectedSize: Int64
    let canDelete: Bool
    let onRescan: () -> Void
    let onDeleteSelected: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LargeOldFilesFormatting.byteFormatter.string(fromByteCount: totalSelectedSize))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("large-old.totalSelected")
            }
            Spacer()
            Button("Re-scan", action: onRescan)
                .accessibilityIdentifier("large-old.rescan")
            Button("Delete Selected", action: onDeleteSelected)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canDelete)
                .accessibilityIdentifier("large-old.delete")
        }
        .padding(16)
    }
}

struct LargeOldFilesEmptyState: View {
    let onScanAgain: () -> Void
    /// Current Full Disk Access state. Drives whether the inline reminder
    /// appears under the "Scan Again" CTA — without it the user can't tell
    /// whether the empty result is genuine or just FDA-blocked.
    let hasFullDiskAccess: Bool
    /// Re-runs the FDA check. Wired to `AppState.refresh()` so the card can
    /// fade out the moment the user grants access in System Settings.
    let onRefreshAccess: () -> Void

    /// Pure predicate so the gate is unit-testable without rendering. The
    /// per-section "this scan needs FDA" decision lives in
    /// `NavigationSection.requiresFullDiskAccess`; here it is unconditional
    /// because Large & Old Files always requires FDA to read ~/Library.
    var shouldShowFullDiskAccessReminder: Bool { !hasFullDiskAccess }

    var body: some View {
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
            Button("Scan Again", action: onScanAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("large-old.scanAgain")

            if shouldShowFullDiskAccessReminder {
                FullDiskAccessPromptCard(
                    accent: .teal,
                    onRecheck: onRefreshAccess
                )
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding()
        .animation(.smooth(duration: 0.4), value: hasFullDiskAccess)
    }
}

struct LargeOldFilesFailedState: View {
    let stage: LargeOldFilesViewModel.FailureStage
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
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
            Button("Try Again", action: onTryAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("large-old.tryAgain")
        }
        .padding()
    }
}

extension ScannedFile: Identifiable {
    var id: URL { url }
}

#Preview("Large Old Files Footer") {
    LargeOldFilesFooter(
        totalSelectedSize: 128_000_000,
        canDelete: true,
        onRescan: {},
        onDeleteSelected: {}
    )
    .frame(width: 800)
}
