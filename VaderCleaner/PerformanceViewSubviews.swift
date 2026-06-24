// PerformanceViewSubviews.swift
// Progress and failure states for the Performance screen.

import SwiftUI

// MARK: - Progress / failed states

struct PerformanceProgressState: View {
    let label: String
    let identifier: String

    var body: some View {
        VStack(spacing: 16) {
            ScanProgressIndicator()
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

struct PerformanceFailedState: View {
    let message: String
    let onDismiss: () -> Void
    /// When set, the failure is recoverable by granting Full Disk Access — the
    /// screen offers a button that jumps straight to that Settings pane.
    var onOpenFullDiskAccess: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(String(
                localized: "That action couldn't complete",
                comment: "Heading on the Performance failure screen."
            ))
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("performance.errorMessage")
            if let onOpenFullDiskAccess {
                Button(String(
                    localized: "Open Full Disk Access Settings",
                    comment: "Recovery button that opens the Full Disk Access settings pane."
                ), action: onOpenFullDiskAccess)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("performance.failureOpenFullDiskAccess")
            }
            Button(String(
                localized: "Back to Performance",
                comment: "Return button on the Performance failure screen."
            ), action: onDismiss)
                .controlSize(.large)
                .keyboardShortcut(onOpenFullDiskAccess == nil ? .defaultAction : nil)
                .accessibilityIdentifier("performance.failurePrimary")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
