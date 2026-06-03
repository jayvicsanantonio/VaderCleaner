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

struct AppUninstallerProgressState: View {
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

struct AppUninstallerListPane: View {
    let apps: [AppInfo]
    let selectedAppID: AppInfo.ID?
    let bundleSize: (AppInfo.ID) -> Int64?
    @Binding var searchQuery: String
    @Binding var includesSystemApps: Bool
    let onSelect: (AppInfo.ID?) -> Void
    let onAddToExclusions: (AppInfo) -> Void
    var iconCache: AppIconCache

    var body: some View {
        VStack(spacing: 0) {
            AppUninstallerSearchField(query: $searchQuery)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if apps.isEmpty {
                AppUninstallerEmptyListState()
            } else {
                List(selection: Binding(
                    get: { selectedAppID },
                    set: { onSelect($0) }
                )) {
                    ForEach(apps) { app in
                        AppUninstallerListRow(app: app,
                                              size: bundleSize(app.id),
                                              iconCache: iconCache)
                            .tag(Optional(app.id))
                            .accessibilityIdentifier("appUninstaller.row.\(app.bundleID)")
                            .contextMenu {
                                Button(String(
                                    localized: "Add to Exclusions",
                                    comment: "Context menu item that adds the selected app to the scan-exclusions list."
                                )) {
                                    onAddToExclusions(app)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            Divider()
            Toggle(isOn: $includesSystemApps) {
                Text(String(
                    localized: "Show system apps",
                    comment: "Toggle that includes com.apple.* apps in the App Uninstaller list."
                ))
                .font(.caption)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("appUninstaller.showSystemApps")
        }
    }
}

struct AppUninstallerSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(
                localized: "Search apps",
                comment: "Placeholder for the App Uninstaller search field."
            ), text: $query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("appUninstaller.search")
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 6))
    }
}

struct AppUninstallerListRow: View {
    let app: AppInfo
    let size: Int64?
    var iconCache: AppIconCache

    var body: some View {
        HStack(spacing: 10) {
            // Cached icon — falls back to the generic application icon
            // until the background pre-load lands. `iconCache` is an
            // ObservedObject so its `revision` bump re-renders this row
            // once the real icon is available.
            Image(nsImage: iconCache.icon(for: app.bundleURL))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let version = app.version {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let size, size > 0 {
                        Text(AppUninstallerFormatting.byteFormatter
                            .string(fromByteCount: size))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct AppUninstallerEmptyListState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "No matching apps",
                comment: "Empty state shown when the App Uninstaller search returns no apps."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
            // Cached icon — see `AppUninstallerListRow` for why the
            // cache is observed.
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
                .buttonStyle(.borderedProminent)
                .disabled(!canUninstall)
                .accessibilityIdentifier("appUninstaller.uninstall")
        }
        .padding(16)
    }
}

struct AppUninstallerCompleteState: View {
    let bytesFreed: Int64
    /// True when the app bundle was permanently removed (App Store / root-owned
    /// app) rather than moved to the Trash, so the copy stays truthful about
    /// whether it can be restored.
    var isPermanentRemoval: Bool = false
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(bytesFreedText)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("appUninstaller.bytesFreed")
            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(String(
                localized: "Continue",
                comment: "Button on the App Uninstaller complete screen to return to the list."
            ), action: onContinue)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("appUninstaller.continue")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var bytesFreedText: String {
        let format = isPermanentRemoval
            ? String(
                localized: "%@ removed",
                comment: "Summary of disk space reclaimed after permanently removing an App Store app."
            )
            : String(
                localized: "%@ moved to Trash",
                comment: "Summary of disk space that will be reclaimed after emptying the Trash."
            )
        return String.localizedStringWithFormat(
            format,
            AppUninstallerFormatting.byteFormatter.string(fromByteCount: bytesFreed)
        )
    }

    private var detailText: String {
        if isPermanentRemoval {
            return String(
                localized: "The app was permanently removed. Its associated files were moved to the Trash where possible.",
                comment: "Detail shown on the App Uninstaller complete screen after permanently removing an App Store app."
            )
        }
        return String(
            localized: "Items were moved to the Trash. Empty the Trash to reclaim the space.",
            comment: "Detail shown on the App Uninstaller complete screen."
        )
    }
}

struct AppUninstallerFailedState: View {
    let stage: AppUninstallerViewModel.FailureStage
    let message: String
    /// When true the failure was the privileged helper being unreachable, so
    /// a "Reinstall Helper" recovery is offered in addition to a plain retry.
    var canReinstallHelper: Bool = false
    var onReinstallHelper: () -> Void = {}
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(stage == .loading
                 ? String(localized: "Couldn't load installed apps")
                 : String(localized: "Couldn't uninstall the app"))
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("appUninstaller.errorMessage")
            if canReinstallHelper {
                // The daemon is unreachable — re-registering it (and approving
                // it in Login Items) is the actual fix, so lead with it.
                Text(String(
                    localized: "Reinstalling the helper re-registers it with the system. You may need to approve VaderCleaner in Login Items, then try again.",
                    comment: "Guidance shown when the App Uninstaller can't reach the privileged helper."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                HStack(spacing: 12) {
                    Button(String(
                        localized: "Reinstall Helper",
                        comment: "Recovery action that re-registers the privileged helper daemon."
                    ), action: onReinstallHelper)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("appUninstaller.reinstallHelper")
                    Button(String(
                        localized: "Try Again",
                        comment: "Retry action on the App Uninstaller failure screen."
                    ), action: onTryAgain)
                        .controlSize(.large)
                        .accessibilityIdentifier("appUninstaller.tryAgain")
                }
            } else {
                Button(String(
                    localized: "Try Again",
                    comment: "Retry action on the App Uninstaller failure screen."
                ), action: onTryAgain)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("appUninstaller.tryAgain")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
