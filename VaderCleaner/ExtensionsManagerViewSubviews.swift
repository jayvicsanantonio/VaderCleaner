// ExtensionsManagerViewSubviews.swift
// Dedicated subviews for the Extensions Manager grouped list, rows, and progress / empty / failed state screens.

import SwiftUI

enum ExtensionsManagerFormatting {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

struct ExtensionsManagerProgressState: View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

struct ExtensionsManagerEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "No extensions found",
                comment: "Empty state heading shown when the Extensions Manager finds nothing."
            ))
                .font(.title3.weight(.semibold))
            Text(String(
                localized: "VaderCleaner didn't find any browser extensions, Mail plugins, internet plug-ins, or login-item launch agents.",
                comment: "Empty state description for the Extensions Manager."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("extensions.empty")
    }
}

struct ExtensionsManagerList: View {
    let groups: [(ExtensionType, [ExtensionItem])]
    let onRemove: (ExtensionItem) -> Void

    var body: some View {
        List {
            ForEach(groups, id: \.0) { pair in
                Section {
                    ForEach(pair.1) { item in
                        ExtensionsManagerRow(item: item) { onRemove(item) }
                            .accessibilityIdentifier("extensions.row.\(pair.0.rawValue).\(item.path.lastPathComponent)")
                    }
                } header: {
                    Text(LocalizedStringKey(pair.0.displayName))
                        .font(.callout.weight(.semibold))
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct ExtensionsManagerRow: View {
    let item: ExtensionItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(1)
                    if !item.isEnabled {
                        Text(String(
                            localized: "Disabled",
                            comment: "Badge shown next to a disabled launch agent / extension."
                        ))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
                Text(item.bundleID ?? item.path.deletingLastPathComponent().path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if item.size > 0 {
                Text(ExtensionsManagerFormatting.byteFormatter
                    .string(fromByteCount: item.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive, action: onRemove) {
                Text(String(
                    localized: "Remove",
                    comment: "Per-row remove button in the Extensions Manager."
                ))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("extensions.remove.\(item.path.lastPathComponent)")
        }
        .padding(.vertical, 2)
    }
}

struct ExtensionsManagerFailedState: View {
    let stage: ExtensionsManagerViewModel.FailureStage
    let message: String
    let onPrimary: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(stage == .loading
                 ? String(localized: "Couldn't scan for extensions",
                          comment: "Heading on the Extensions Manager failure screen when discovery failed.")
                 : String(localized: "Couldn't remove the extension",
                          comment: "Heading on the Extensions Manager failure screen when removal failed."))
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("extensions.errorMessage")
            Button(stage == .loading
                   ? String(localized: "Try Again",
                            comment: "Retry discovery on the Extensions Manager failure screen.")
                   : String(localized: "Back to Extensions",
                            comment: "Return to the list after a failed Extensions Manager removal."),
                   action: onPrimary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("extensions.failurePrimary")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
