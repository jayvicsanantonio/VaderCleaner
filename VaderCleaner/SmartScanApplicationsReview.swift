// SmartScanApplicationsReview.swift
// Per-update toggle list for the Smart Scan Applications Review screen.

import SwiftUI

/// Per-update toggle list for the Applications Review.
struct SmartScanApplicationsReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SmartScanReviewHeader(
                title: String(
                    localized: "Applications Manager",
                    comment: "Title on the Smart Scan Applications Review screen."
                ),
                onBack: onBack
            )
            List {
                ForEach(result.availableUpdates, id: \.id) { update in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.isUpdateSelected(update) },
                            set: { _ in viewModel.toggleUpdate(update) }
                        ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.appName)
                                .font(.body.weight(.medium))
                            Text("\(update.installedVersion) → \(update.latestVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("smartScan.review.applications")
    }
}
