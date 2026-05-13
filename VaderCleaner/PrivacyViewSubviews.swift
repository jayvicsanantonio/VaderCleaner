// PrivacyViewSubviews.swift
// Dedicated subviews for PrivacyView state screens, preview sections, rows, and footer.

import SwiftUI

enum PrivacyViewFormatting {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

struct PrivacyIdleState: View {
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "Privacy",
                comment: "Title for the Privacy cleanup feature."
            ))
                .font(.title2.weight(.semibold))
            Text(String(
                localized: "Clear browsing history, downloads, cookies, cache, saved form data across detected browsers, and the system Recent Items list.",
                comment: "Description of what the Privacy cleanup feature can clear."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan", action: onScan)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy.scan")
        }
        .padding()
    }
}

struct PrivacyProgressState: View {
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

struct PrivacyPreviewContent: View {
    let browsers: [Browser]
    let totalSelectedSize: Int64
    let isClearRecentsChecked: Bool
    let canClear: Bool
    let sizeOnDisk: (Browser) -> Int64
    let categorySize: (Browser, PrivacyCategory) -> Int64
    let isCategoryActionable: (Browser, PrivacyCategory) -> Bool
    let isCategoryChecked: (Browser, PrivacyCategory) -> Bool
    let onToggleCategory: (Browser, PrivacyCategory) -> Void
    let onToggleClearRecents: () -> Void
    let onRescan: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(browsers) { browser in
                    PrivacyBrowserSection(
                        browser: browser,
                        totalBytes: sizeOnDisk(browser),
                        categorySize: { categorySize(browser, $0) },
                        isCategoryActionable: { isCategoryActionable(browser, $0) },
                        isCategoryChecked: { isCategoryChecked(browser, $0) },
                        onToggleCategory: { onToggleCategory(browser, $0) }
                    )
                }

                Section {
                    PrivacyRecentItemsRow(
                        isChecked: isClearRecentsChecked,
                        onToggle: onToggleClearRecents
                    )
                } header: {
                    Text("System")
                        .font(.callout.weight(.semibold))
                }
            }
            Divider()
            PrivacyPreviewFooter(
                totalSelectedSize: totalSelectedSize,
                canClear: canClear,
                onRescan: onRescan,
                onClear: onClear
            )
        }
    }
}

struct PrivacyBrowserSection: View {
    let browser: Browser
    let totalBytes: Int64
    let categorySize: (PrivacyCategory) -> Int64
    let isCategoryActionable: (PrivacyCategory) -> Bool
    let isCategoryChecked: (PrivacyCategory) -> Bool
    let onToggleCategory: (PrivacyCategory) -> Void

    var body: some View {
        Section {
            ForEach(PrivacyCategory.allCases) { category in
                if isCategoryActionable(category) {
                    PrivacyCategoryRow(
                        category: category,
                        sizeBytes: categorySize(category),
                        isChecked: Binding(
                            get: { isCategoryChecked(category) },
                            set: { _ in onToggleCategory(category) }
                        )
                    )
                    .accessibilityIdentifier("privacy.row.\(browser.rawValue).\(category.rawValue)")
                } else {
                    PrivacyCoupledCategoryRow(category: category)
                        .accessibilityIdentifier("privacy.row.\(browser.rawValue).\(category.rawValue).coupled")
                }
            }
        } header: {
            PrivacyBrowserHeader(browser: browser, totalBytes: totalBytes)
        }
    }
}

struct PrivacyBrowserHeader: View {
    let browser: Browser
    let totalBytes: Int64

    var body: some View {
        HStack(spacing: 8) {
            Text(browser.displayName)
                .font(.callout.weight(.semibold))
            Spacer()
            Text(PrivacyViewFormatting.byteFormatter.string(fromByteCount: totalBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Row rendered for categories whose data is coupled to another browser
/// category at the file level.
struct PrivacyCoupledCategoryRow: View {
    let category: PrivacyCategory

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 16)
            Text(category.displayName)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(
                localized: "Included with Browsing History",
                comment: "Explanation for why a privacy category cannot be cleared independently."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct PrivacyCategoryRow: View {
    let category: PrivacyCategory
    let sizeBytes: Int64
    @Binding var isChecked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(category.displayName)
                .font(.body)
            Spacer()
            Text(PrivacyViewFormatting.byteFormatter.string(fromByteCount: sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct PrivacyRecentItemsRow: View {
    let isChecked: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isChecked },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text("System Recent Items")
                    .font(.body.weight(.medium))
                Text("Clears the Apple-menu Recent Items list and this app's recent documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("privacy.row.recentItems")
    }
}

struct PrivacyPreviewFooter: View {
    let totalSelectedSize: Int64
    let canClear: Bool
    let onRescan: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(PrivacyViewFormatting.byteFormatter.string(fromByteCount: totalSelectedSize))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("privacy.totalSelected")
            }
            Spacer()
            Button("Re-scan", action: onRescan)
                .accessibilityIdentifier("privacy.rescan")
            Button("Clear", action: onClear)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canClear)
                .accessibilityIdentifier("privacy.clear")
        }
        .padding(16)
    }
}

struct PrivacyCompleteState: View {
    let bytesFreed: Int64
    let onScanAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(bytesFreedText)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("privacy.bytesFreed")
            Text("Browsers may need to be restarted before disk space fully reflects the change.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan Again", action: onScanAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy.scanAgain")
        }
        .padding()
    }

    private var bytesFreedText: String {
        let format = String(
            localized: "%@ freed",
            comment: "Summary of disk space freed after clearing privacy data."
        )
        return String.localizedStringWithFormat(
            format,
            PrivacyViewFormatting.byteFormatter.string(fromByteCount: bytesFreed)
        )
    }
}

struct PrivacyFailedState: View {
    let stage: PrivacyViewModel.FailureStage
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(stage == .scanning ? "Couldn't complete the scan" : "Couldn't finish clearing")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("privacy.errorMessage")
            Button("Try Again", action: onTryAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy.tryAgain")
        }
        .padding()
    }
}

#Preview("Privacy Row") {
    PrivacyCategoryRow(category: .history, sizeBytes: 12_000_000, isChecked: .constant(true))
        .padding()
        .frame(width: 460)
}

#Preview("Privacy Footer") {
    PrivacyPreviewFooter(
        totalSelectedSize: 42_000_000,
        canClear: true,
        onRescan: {},
        onClear: {}
    )
    .frame(width: 700)
}
