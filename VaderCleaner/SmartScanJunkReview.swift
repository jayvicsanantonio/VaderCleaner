// SmartScanJunkReview.swift
// Per-category toggle list for the Smart Scan System Junk Review screen.

import SwiftUI

/// Per-category toggle list for the System Junk Review. Reuses the row
/// idiom from `SystemJunkView.CategoryRow` so the two surfaces stay visually
/// consistent.
struct SmartScanJunkReview: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onBack: () -> Void

    private var categories: [ScanCategory] {
        ScanCategory.allCases.filter { result.junkResult.itemsByCategory[$0] != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            SmartScanReviewHeader(
                title: String(
                    localized: "Cleanup Manager",
                    comment: "Title on the Smart Scan System Junk Review screen."
                ),
                onBack: onBack
            )
            List {
                ForEach(categories, id: \.self) { category in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.isJunkCategorySelected(category) },
                            set: { _ in viewModel.toggleJunkCategory(category) }
                        ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.displayName)
                                .font(.body.weight(.medium))
                            let count = result.junkResult.itemsByCategory[category]?.count ?? 0
                            Text("\(count) item\(count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(smartScanByteFormatter.string(
                            fromByteCount: result.junkResult.sizeByCategory[category] ?? 0
                        ))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("smartScan.review.junk.\(category.rawValue)")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("smartScan.review.junk")
    }
}
