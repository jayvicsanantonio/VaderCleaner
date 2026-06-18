// PrivacyViewSubviews.swift
// Dedicated subviews for PrivacyView state screens and the Recent Items row.

import SwiftUI

enum PrivacyViewFormatting {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

struct PrivacyProgressState: View {
    let label: String
    let identifier: String
    /// Optional live progress line (e.g. "24 items") shown beneath the status
    /// phrase so the user can see the scan advancing.
    var detail: String? = nil
    /// Rotating personality phrases for the open scan; falls back to `label`.
    var phrases: [String]? = nil

    var body: some View {
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
            .accessibilityLabel(Text(recentItemsTitle))
            VStack(alignment: .leading, spacing: 2) {
                Text(recentItemsTitle)
                    .font(.body.weight(.medium))
                Text(recentItemsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("privacy.row.recentItems")
    }

    private var recentItemsTitle: String {
        String(
            localized: "System Recent Items",
            comment: "Title for the option that clears the macOS Recent Items list."
        )
    }

    private var recentItemsDescription: String {
        String(
            localized: "Clears the Apple-menu Recent Items list and this app's recent documents.",
            comment: "Description for the option that clears system recent items."
        )
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

