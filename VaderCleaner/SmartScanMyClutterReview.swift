// SmartScanMyClutterReview.swift
// Per-file toggle list for the Smart Scan My Clutter Review, with Select All / Clear bulk actions in the footer.

import SwiftUI

/// Per-file toggle list for the My Clutter Review. Defaults to nothing
/// selected (destructive deletes are opt-in); a footer offers Select All /
/// Clear bulk actions.
struct SmartScanMyClutterReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onBack: () -> Void

    /// Pre-sorted by `SmartScanViewModel` once when results land — reading
    /// it here keeps the body free of O(N log N) work on every refresh
    /// triggered by toggling individual files.
    private var sortedFiles: [ScannedFile] {
        viewModel.sortedLargeOldFiles
    }

    var body: some View {
        VStack(spacing: 0) {
            SmartScanReviewHeader(
                title: String(
                    localized: "Clutter Manager",
                    comment: "Title on the Smart Scan My Clutter Review screen."
                ),
                onBack: onBack
            )
            List {
                ForEach(sortedFiles, id: \.url) { file in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.isLargeFileSelected(file) },
                            set: { _ in viewModel.toggleLargeFile(file) }
                        ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.url.lastPathComponent)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(file.url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(smartScanByteFormatter.string(fromByteCount: file.size))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 12) {
                Button(String(
                    localized: "Select All",
                    comment: "Bulk action on the Smart Scan My Clutter Review — opt every file in for removal."
                )) {
                    // Single write to `largeFileSelection` — SwiftUI sees
                    // one publish, not N. Per-file iteration here used to
                    // stall the UI on large clutter scans.
                    viewModel.selectAllLargeFiles()
                }
                .accessibilityIdentifier("smartScan.review.myClutter.selectAll")
                Button(String(
                    localized: "Clear",
                    comment: "Bulk action on the Smart Scan My Clutter Review — opt every file out of removal."
                )) {
                    viewModel.clearLargeFileSelection()
                }
                .accessibilityIdentifier("smartScan.review.myClutter.clear")
                Spacer()
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("smartScan.review.myClutter")
    }
}
