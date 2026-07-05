// AppUninstallerViewSubviews.swift
// Dedicated subviews for App Uninstaller list pane, detail pane, file rows, and state screens.

import AppKit
import SwiftUI

enum AppUninstallerFormatting {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

struct AppUninstallerDetailPane: View {
    let app: AppInfo?
    let bundleSize: Int64?
    let isLoadingAssociatedFiles: Bool
    let groupedFiles: [(AssociatedFileCategory, [AssociatedFile])]
    let totalReclaimableSize: Int64
    let canUninstall: Bool
    let onUninstall: () -> Void
    var iconCache: AppIconCache

    var body: some View {
        if let app {
            VStack(spacing: 0) {
                AppUninstallerDetailHeader(app: app, bundleSize: bundleSize, iconCache: iconCache)
                Divider()
                if isLoadingAssociatedFiles {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(String(
                            localized: "Scanning associated files…",
                            comment: "Status text shown while the App Uninstaller scans for associated files."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if groupedFiles.isEmpty {
                    AppUninstallerNoAssociatedFiles()
                } else {
                    AppUninstallerAssociatedFilesList(groupedFiles: groupedFiles)
                }
                Divider()
                AppUninstallerDetailFooter(
                    totalReclaimableSize: totalReclaimableSize,
                    canUninstall: canUninstall,
                    onUninstall: onUninstall
                )
            }
        } else {
            AppUninstallerNoSelectionState()
        }
    }
}

struct AppUninstallerDetailHeader: View {
    let app: AppInfo
    let bundleSize: Int64?
    var iconCache: AppIconCache

    var body: some View {
        HStack(spacing: 14) {
            // Cached icon — `iconCache` is observed so its `revision` bump
            // re-renders this row once the real icon is available.
            Image(nsImage: iconCache.icon(for: app.bundleURL))
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                Text(app.bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let version = app.version {
                        Label(version, systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if app.isAppStore {
                        Label(String(
                            localized: "App Store",
                            comment: "Badge shown next to apps installed via the Mac App Store."
                        ), systemImage: "bag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let bundleSize {
                        Text(AppUninstallerFormatting.byteFormatter
                            .string(fromByteCount: bundleSize))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(16)
    }
}

struct AppUninstallerNoSelectionState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.app")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "Select an app",
                comment: "Detail-pane heading shown when no app is selected in the App Uninstaller."
            ))
                .font(.title3.weight(.semibold))
            Text(String(
                localized: "Pick an app from the list to see its associated files and uninstall it.",
                comment: "Detail-pane description shown when no app is selected in the App Uninstaller."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppUninstallerNoAssociatedFiles: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "No associated files found",
                comment: "Empty state shown when an app has no associated files."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(
                localized: "Only the app bundle will be moved to Trash.",
                comment: "Detail shown when an app has no associated files."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppUninstallerAssociatedFilesList: View {
    let groupedFiles: [(AssociatedFileCategory, [AssociatedFile])]

    var body: some View {
        List {
            ForEach(groupedFiles, id: \.0) { pair in
                Section {
                    ForEach(pair.1) { file in
                        AppUninstallerFileRow(file: file)
                            .accessibilityIdentifier("appUninstaller.file.\(pair.0.rawValue).\(file.url.lastPathComponent)")
                    }
                } header: {
                    Text(pair.0.displayName)
                        .font(.callout.weight(.semibold))
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

struct AppUninstallerFileRow: View {
    let file: AssociatedFile

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(AppUninstallerFormatting.byteFormatter
                .string(fromByteCount: file.sizeBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct AppUninstallerDetailFooter: View {
    let totalReclaimableSize: Int64
    let canUninstall: Bool
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    localized: "Total reclaimable",
                    comment: "Footer label showing the total size that will be reclaimed when an app is uninstalled."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppUninstallerFormatting.byteFormatter
                    .string(fromByteCount: totalReclaimableSize))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("appUninstaller.totalReclaimable")
            }
            Spacer()
            // Disabled while the associated-files scan is in flight so a
            // user who confirms early can't ship the bundle to Trash and
            // leave caches / preferences behind — the confirmation alert
            // promises "app and its associated files" will be moved.
            Button(String(
                localized: "Uninstall",
                comment: "Primary action button on the App Uninstaller detail pane."
            ), action: onUninstall)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.vaderProminent)
                .disabled(!canUninstall)
                .accessibilityIdentifier("appUninstaller.uninstall")
        }
        .padding(16)
    }
}
