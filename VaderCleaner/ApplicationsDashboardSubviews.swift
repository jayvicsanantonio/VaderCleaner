// ApplicationsDashboardSubviews.swift
// Post-scan dashboard for the Applications section — the "N apps found" header, the summary card grid, and the progress / failed states.

import SwiftUI

// MARK: - Dashboard

/// The Applications landing surface after a scan: a headline count, a "Manage
/// My Applications" affordance, and the summary cards in an adaptive grid —
/// mirroring the Optimization dashboard's card layout.
struct ApplicationsDashboardView: View {
    let result: ApplicationsScanResult
    let onOpenUpdates: () -> Void
    let onOpenManage: () -> Void
    let onOpenInstallationFiles: () -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            header
            grid
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("applications.dashboard")
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text(installedCountText)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("applications.installedCount")

            HStack(spacing: 12) {
                Button(action: onOpenManage) {
                    Text(String(
                        localized: "Manage My Applications",
                        comment: "Button that opens the full installed-apps management (uninstaller) list."
                    ))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("applications.manageMyApplications")

                Button(action: onRescan) {
                    Text(String(
                        localized: "Rescan",
                        comment: "Button that re-runs the Applications scan."
                    ))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("applications.rescan")
            }
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260), spacing: 16)],
            alignment: .leading,
            spacing: 16
        ) {
            ApplicationsCard(
                title: updatesTitle,
                detail: updatesDetail,
                icon: "arrow.triangle.2.circlepath",
                actionLabel: String(
                    localized: "Review",
                    comment: "Applications Updates card action that opens the update list."
                ),
                identifier: "applications.card.updates",
                action: onOpenUpdates
            )
            ApplicationsCard(
                title: installationFilesTitle,
                detail: installationFilesDetail,
                icon: "shippingbox",
                actionLabel: String(
                    localized: "Review",
                    comment: "Applications Installation Files card action that opens the installer list."
                ),
                identifier: "applications.card.installationFiles",
                action: onOpenInstallationFiles
            )
            ApplicationsCard(
                title: String(
                    localized: "Manage Applications",
                    comment: "Applications management card title."
                ),
                detail: manageDetail,
                icon: "square.grid.2x2",
                actionLabel: String(
                    localized: "Manage",
                    comment: "Applications management card action."
                ),
                identifier: "applications.card.manage",
                action: onOpenManage
            )
        }
    }

    // MARK: Copy

    private var installedCountText: String {
        let format = String(
            localized: "We've found %lld apps on your Mac.",
            comment: "Applications dashboard headline; %lld is the installed-app count."
        )
        return String.localizedStringWithFormat(format, Int64(result.installedCount))
    }

    private var updatesTitle: String {
        if result.updatesCount == 0 {
            return String(
                localized: "No Updates Available",
                comment: "Applications Updates card title when every app is current."
            )
        }
        let format = String(
            localized: "%lld Application Updates Available",
            comment: "Applications Updates card title; %lld is the available-update count."
        )
        return String.localizedStringWithFormat(format, Int64(result.updatesCount))
    }

    private var updatesDetail: String {
        if result.updatesCount == 0 {
            return String(
                localized: "All your apps are running the latest version.",
                comment: "Applications Updates card detail when no updates are available."
            )
        }
        return String(
            localized: "Update your software to keep up with the latest features and compatibility improvements.",
            comment: "Applications Updates card detail when updates are available."
        )
    }

    private var manageDetail: String {
        let format = String(
            localized: "Browse all %lld installed apps and remove the ones you no longer need, along with their leftover files.",
            comment: "Applications management card detail; %lld is the installed-app count."
        )
        return String.localizedStringWithFormat(format, Int64(result.installedCount))
    }

    private var installationFilesTitle: String {
        if result.installationFilesCount == 0 {
            return String(
                localized: "No Installation Files",
                comment: "Applications Installation Files card title when none are found."
            )
        }
        let format = String(
            localized: "%lld Installation Files Found",
            comment: "Applications Installation Files card title; %lld is the installer count."
        )
        return String.localizedStringWithFormat(format, Int64(result.installationFilesCount))
    }

    private var installationFilesDetail: String {
        if result.installationFilesCount == 0 {
            return String(
                localized: "No leftover disk images or installer packages in your Downloads or Desktop.",
                comment: "Applications Installation Files card detail when none are found."
            )
        }
        let size = smartScanByteFormatter.string(fromByteCount: result.installationFilesTotalBytes)
        let format = String(
            localized: "Leftover disk images and installers in your Downloads and Desktop are using %@. They're safe to remove once an app is installed.",
            comment: "Applications Installation Files card detail; %@ is the reclaimable size."
        )
        return String.localizedStringWithFormat(format, size)
    }
}

/// A single Applications summary card. Uses the same glass surface and corner
/// radius as the Optimization / Smart Scan dashboards so the app's card
/// surfaces stay consistent.
struct ApplicationsCard: View {
    let title: String
    let detail: String
    let icon: String
    let actionLabel: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack {
                Spacer()
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Installation Files review

/// The Installation Files detail screen: a multi-select list of leftover
/// installers with a pinned Remove bar that moves the selected ones to the
/// Trash. Selection is opt-in (destructive), mirroring the Large & Old Files
/// review.
struct InstallationFilesReviewView: View {
    let files: [InstallationFile]
    let isSelected: (InstallationFile) -> Bool
    let onToggle: (InstallationFile) -> Void
    let onSelectAll: () -> Void
    let onClear: () -> Void
    let isRemoving: Bool
    let canRemove: Bool
    let onRemove: () -> Void

    private var selectedFiles: [InstallationFile] { files.filter(isSelected) }
    private var selectedBytes: Int64 { selectedFiles.reduce(Int64(0)) { $0 + $1.sizeBytes } }
    private var allSelected: Bool { !files.isEmpty && selectedFiles.count == files.count }

    var body: some View {
        if files.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                selectAllBar
                Divider()
                List {
                    ForEach(files) { file in
                        InstallationFileRow(
                            file: file,
                            isSelected: isSelected(file),
                            onToggle: { onToggle(file) }
                        )
                        .accessibilityIdentifier("applications.installationFiles.row.\(file.name)")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                Divider()
                removeBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("applications.installationFiles")
        }
    }

    private var selectAllBar: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { allSelected },
                set: { $0 ? onSelectAll() : onClear() }
            )) {
                Text(String(
                    localized: "Select All",
                    comment: "Toggle that selects/deselects every installation file."
                ))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("applications.installationFiles.selectAll")
            Spacer()
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var removeBar: some View {
        HStack(spacing: 12) {
            Text(selectionSummary)
                .font(.callout.weight(.medium))
            Spacer()
            if isRemoving {
                ProgressView().controlSize(.small)
            }
            Button(String(
                localized: "Move to Trash",
                comment: "Button that moves the selected installation files to the Trash."
            ), action: onRemove)
                .buttonStyle(.borderedProminent)
                .disabled(!canRemove)
                .accessibilityIdentifier("applications.installationFiles.remove")
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(String(
                localized: "No installation files",
                comment: "Empty state on the Installation Files review."
            ))
            .font(.title3.weight(.semibold))
            Text(String(
                localized: "Your Downloads and Desktop have no leftover disk images or installer packages.",
                comment: "Empty-state detail on the Installation Files review."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.installationFiles.empty")
    }

    private var countText: String {
        let total = smartScanByteFormatter.string(fromByteCount: files.reduce(Int64(0)) { $0 + $1.sizeBytes })
        let format = String(
            localized: "%lld files · %@",
            comment: "Installation Files header count; %lld is the count, %@ the total size."
        )
        return String.localizedStringWithFormat(format, Int64(files.count), total)
    }

    private var selectionSummary: String {
        let size = smartScanByteFormatter.string(fromByteCount: selectedBytes)
        let format = String(
            localized: "%lld selected · %@",
            comment: "Installation Files remove-bar summary; %lld is the selected count, %@ the selected size."
        )
        return String.localizedStringWithFormat(format, Int64(selectedFiles.count), size)
    }
}

/// One installation-file row: a checkbox, a kind badge, the file name, and its
/// size.
private struct InstallationFileRow: View {
    let file: InstallationFile
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(systemName: kindSymbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(smartScanByteFormatter.string(fromByteCount: file.sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .padding(.vertical, 4)
    }

    private var kindSymbol: String {
        switch file.kind {
        case .diskImage: return "opticaldiscdrive"
        case .package:   return "shippingbox"
        }
    }

    private var kindLabel: String {
        switch file.kind {
        case .diskImage:
            return String(localized: "Disk image", comment: "Installation file kind label.")
        case .package:
            return String(localized: "Installer package", comment: "Installation file kind label.")
        }
    }
}

// MARK: - Progress

/// Centered spinner shown while the Applications scan runs.
struct ApplicationsProgressState: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(String(
                localized: "Scanning your applications…",
                comment: "Progress label shown while the Applications scan runs."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.loading")
    }
}

// MARK: - Failed

/// Error state for a failed Applications scan, with a retry that re-runs it.
struct ApplicationsFailedState: View {
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(String(
                localized: "Couldn't scan your applications",
                comment: "Title shown on the Applications scan failure screen."
            ))
            .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("applications.errorMessage")
            Button(String(
                localized: "Try Again",
                comment: "Retry button on the Applications scan failure screen."
            ), action: onTryAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("applications.tryAgain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
