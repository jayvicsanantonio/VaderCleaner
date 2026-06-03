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
    let onOpenUnsupported: () -> Void
    let onOpenUnused: () -> Void
    let onOpenLeftovers: () -> Void
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

    /// One dashboard card's content. Built as data so the layout can promote
    /// the first one to a tall hero and flow the rest through an adaptive grid
    /// (mirroring the Optimization dashboard), rather than every card sharing
    /// one fixed size.
    private struct CardSpec: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let actionLabel: String
        let action: () -> Void
    }

    private var reviewLabel: String {
        String(localized: "Review", comment: "Applications card action that opens a review list.")
    }

    /// Height of a standard card, and of a tall card — a tall card spans
    /// exactly two standard cards plus the gap between them, so the two columns
    /// stay the same total height (each is one tall + two standard + two gaps).
    private let standardCardHeight: CGFloat = 150
    private var tallCardHeight: CGFloat { standardCardHeight * 2 + 16 }

    private var updatesSpec: CardSpec {
        CardSpec(id: "applications.card.updates", title: updatesTitle, detail: updatesDetail,
                 icon: "arrow.triangle.2.circlepath", actionLabel: reviewLabel, action: onOpenUpdates)
    }
    private var unusedSpec: CardSpec {
        CardSpec(id: "applications.card.unused", title: unusedTitle, detail: unusedDetail,
                 icon: "moon.zzz", actionLabel: reviewLabel, action: onOpenUnused)
    }
    private var unsupportedSpec: CardSpec {
        CardSpec(id: "applications.card.unsupported", title: unsupportedTitle, detail: unsupportedDetail,
                 icon: "exclamationmark.triangle", actionLabel: reviewLabel, action: onOpenUnsupported)
    }
    private var leftoversSpec: CardSpec {
        CardSpec(id: "applications.card.leftovers", title: leftoversTitle, detail: leftoversDetail,
                 icon: "trash", actionLabel: reviewLabel, action: onOpenLeftovers)
    }
    private var installationFilesSpec: CardSpec {
        CardSpec(id: "applications.card.installationFiles", title: installationFilesTitle,
                 detail: installationFilesDetail, icon: "shippingbox", actionLabel: reviewLabel,
                 action: onOpenInstallationFiles)
    }
    private var manageSpec: CardSpec {
        CardSpec(id: "applications.card.manage",
                 title: String(localized: "Manage Applications", comment: "Applications management card title."),
                 detail: manageDetail, icon: "square.grid.2x2",
                 actionLabel: String(localized: "Manage", comment: "Applications management card action."),
                 action: onOpenManage)
    }

    /// Two-column masonry. The left column leads with the tall Updates card
    /// over two standard cards; the right column mirrors it with two standard
    /// cards over the tall Leftovers card — so the two tall tiles sit on a
    /// diagonal and the columns stay equal height.
    private var grid: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                card(updatesSpec, height: tallCardHeight)
                card(installationFilesSpec, height: standardCardHeight)
                card(manageSpec, height: standardCardHeight)
            }
            VStack(spacing: 16) {
                card(unusedSpec, height: standardCardHeight)
                card(unsupportedSpec, height: standardCardHeight)
                card(leftoversSpec, height: tallCardHeight)
            }
        }
    }

    private func card(_ spec: CardSpec, height: CGFloat) -> some View {
        ApplicationsCard(
            title: spec.title,
            detail: spec.detail,
            icon: spec.icon,
            actionLabel: spec.actionLabel,
            identifier: spec.id,
            height: height,
            action: spec.action
        )
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

    private var unusedTitle: String {
        if result.unusedAppsCount == 0 {
            return String(
                localized: "No Unused Applications",
                comment: "Applications Unused card title when none are found."
            )
        }
        let format = String(
            localized: "%lld Unused Applications Found",
            comment: "Applications Unused card title; %lld is the count."
        )
        return String.localizedStringWithFormat(format, Int64(result.unusedAppsCount))
    }

    private var unusedDetail: String {
        if result.unusedAppsCount == 0 {
            return String(
                localized: "Every app has been opened recently.",
                comment: "Applications Unused card detail when none are found."
            )
        }
        return String(
            localized: "These apps haven't been opened in over 60 days. Remove the ones you no longer need.",
            comment: "Applications Unused card detail when some are found."
        )
    }

    private var leftoversTitle: String {
        if result.leftoversCount == 0 {
            return String(
                localized: "No App Leftovers",
                comment: "Applications Leftovers card title when none are found."
            )
        }
        let format = String(
            localized: "Leftovers From %lld Apps Found",
            comment: "Applications Leftovers card title; %lld is the orphaned-app count."
        )
        return String.localizedStringWithFormat(format, Int64(result.leftoversCount))
    }

    private var leftoversDetail: String {
        if result.leftoversCount == 0 {
            return String(
                localized: "No support files from uninstalled apps were found.",
                comment: "Applications Leftovers card detail when none are found."
            )
        }
        let size = smartScanByteFormatter.string(fromByteCount: result.leftoversTotalBytes)
        let format = String(
            localized: "Support files left behind by apps you've removed are using %@.",
            comment: "Applications Leftovers card detail; %@ is the reclaimable size."
        )
        return String.localizedStringWithFormat(format, size)
    }

    private var unsupportedTitle: String {
        if result.unsupportedAppsCount == 0 {
            return String(
                localized: "No Unsupported Applications",
                comment: "Applications Unsupported card title when none are found."
            )
        }
        let format = String(
            localized: "%lld Unsupported Applications Found",
            comment: "Applications Unsupported card title; %lld is the count."
        )
        return String.localizedStringWithFormat(format, Int64(result.unsupportedAppsCount))
    }

    private var unsupportedDetail: String {
        if result.unsupportedAppsCount == 0 {
            return String(
                localized: "Every installed app can run on this version of macOS.",
                comment: "Applications Unsupported card detail when none are found."
            )
        }
        return String(
            localized: "These apps won't run on this version of macOS — their code is built only for older architectures.",
            comment: "Applications Unsupported card detail when some are found."
        )
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
    /// Fixed card height set by the layout — tall cards span two standard cards
    /// so the grid isn't a uniform row of equal-size tiles. A fixed height (not
    /// a min) keeps the card from stretching to fill its column.
    let height: CGFloat
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
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
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

// MARK: - Unsupported Applications review

/// The Unsupported Applications detail screen: a multi-select list of apps that
/// can't run on the current macOS, with a pinned Move to Trash bar. Only the
/// `.app` bundle is removed here; full associated-file cleanup is available via
/// Manage (the uninstaller).
struct UnsupportedAppsReviewView: View {
    let apps: [UnsupportedApp]
    var iconCache: AppIconCache
    let isSelected: (UnsupportedApp) -> Bool
    let onToggle: (UnsupportedApp) -> Void
    let onSelectAll: () -> Void
    let onClear: () -> Void
    let isRemoving: Bool
    let canRemove: Bool
    let onRemove: () -> Void

    private var selectedCount: Int { apps.filter(isSelected).count }
    private var allSelected: Bool { !apps.isEmpty && selectedCount == apps.count }

    var body: some View {
        if apps.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                selectAllBar
                Divider()
                List {
                    ForEach(apps) { entry in
                        UnsupportedAppRow(
                            entry: entry,
                            iconCache: iconCache,
                            isSelected: isSelected(entry),
                            onToggle: { onToggle(entry) }
                        )
                        .accessibilityIdentifier("applications.unsupported.row.\(entry.app.bundleID)")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                Divider()
                removeBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("applications.unsupported")
            .task(id: apps.map(\.id)) {
                await iconCache.preloadIcons(for: apps.map(\.app.bundleURL))
            }
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
                    comment: "Toggle that selects/deselects every unsupported app."
                ))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("applications.unsupported.selectAll")
            Spacer()
            Text(headerCountText)
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
                comment: "Button that moves the selected unsupported apps to the Trash."
            ), action: onRemove)
                .buttonStyle(.borderedProminent)
                .disabled(!canRemove)
                .accessibilityIdentifier("applications.unsupported.remove")
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(String(
                localized: "No unsupported applications",
                comment: "Empty state on the Unsupported Applications review."
            ))
            .font(.title3.weight(.semibold))
            Text(String(
                localized: "Every installed app can run on this version of macOS.",
                comment: "Empty-state detail on the Unsupported Applications review."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.unsupported.empty")
    }

    private var headerCountText: String {
        let format = String(
            localized: "%lld apps",
            comment: "Unsupported Applications header count."
        )
        return String.localizedStringWithFormat(format, Int64(apps.count))
    }

    private var selectionSummary: String {
        let format = String(
            localized: "%lld selected",
            comment: "Unsupported Applications remove-bar summary; %lld is the selected count."
        )
        return String.localizedStringWithFormat(format, Int64(selectedCount))
    }
}

/// One unsupported-app row: a checkbox, an alert badge, the app name, and the
/// reason it can't run.
private struct UnsupportedAppRow: View {
    let entry: UnsupportedApp
    var iconCache: AppIconCache
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(nsImage: iconCache.icon(for: entry.app.bundleURL))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.app.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reasonText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .padding(.vertical, 4)
    }

    private var reasonText: String {
        switch entry.reason {
        case .incompatibleArchitecture:
            return String(
                localized: "Won't run on this macOS — built for an older architecture",
                comment: "Reason label for an unsupported app with no runnable architecture."
            )
        }
    }
}

// MARK: - Unused Applications review

/// The Unused Applications detail screen: a multi-select list of apps not
/// opened in a long time, with a pinned Move to Trash bar. Only the `.app`
/// bundle is moved here; full associated-file cleanup is available via Manage.
struct UnusedAppsReviewView: View {
    let apps: [UnusedApp]
    var iconCache: AppIconCache
    let isSelected: (UnusedApp) -> Bool
    let onToggle: (UnusedApp) -> Void
    let onSelectAll: () -> Void
    let onClear: () -> Void
    let isRemoving: Bool
    let canRemove: Bool
    let onRemove: () -> Void

    private var selectedCount: Int { apps.filter(isSelected).count }
    private var allSelected: Bool { !apps.isEmpty && selectedCount == apps.count }

    var body: some View {
        if apps.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                selectAllBar
                Divider()
                List {
                    ForEach(apps) { entry in
                        UnusedAppRow(
                            entry: entry,
                            iconCache: iconCache,
                            isSelected: isSelected(entry),
                            onToggle: { onToggle(entry) }
                        )
                        .accessibilityIdentifier("applications.unused.row.\(entry.app.bundleID)")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                Divider()
                removeBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("applications.unused")
            .task(id: apps.map(\.id)) {
                await iconCache.preloadIcons(for: apps.map(\.app.bundleURL))
            }
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
                    comment: "Toggle that selects/deselects every unused app."
                ))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("applications.unused.selectAll")
            Spacer()
            Text(headerCountText)
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
                comment: "Button that moves the selected unused apps to the Trash."
            ), action: onRemove)
                .buttonStyle(.borderedProminent)
                .disabled(!canRemove)
                .accessibilityIdentifier("applications.unused.remove")
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(String(
                localized: "No unused applications",
                comment: "Empty state on the Unused Applications review."
            ))
            .font(.title3.weight(.semibold))
            Text(String(
                localized: "Every installed app has been opened recently.",
                comment: "Empty-state detail on the Unused Applications review."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.unused.empty")
    }

    private var headerCountText: String {
        let format = String(localized: "%lld apps", comment: "Unused Applications header count.")
        return String.localizedStringWithFormat(format, Int64(apps.count))
    }

    private var selectionSummary: String {
        let format = String(
            localized: "%lld selected",
            comment: "Unused Applications remove-bar summary; %lld is the selected count."
        )
        return String.localizedStringWithFormat(format, Int64(selectedCount))
    }
}

/// One unused-app row: a checkbox, a sleep badge, the app name, and how long
/// since it was last opened.
private struct UnusedAppRow: View {
    let entry: UnusedApp
    var iconCache: AppIconCache
    let isSelected: Bool
    let onToggle: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(nsImage: iconCache.icon(for: entry.app.bundleURL))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.app.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(lastUsedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .padding(.vertical, 4)
    }

    private var lastUsedText: String {
        let relative = Self.relativeFormatter.localizedString(for: entry.lastUsedDate, relativeTo: Date())
        let format = String(
            localized: "Last opened %@",
            comment: "Unused-app row subtitle; %@ is a relative date like \"3 months ago\"."
        )
        return String.localizedStringWithFormat(format, relative)
    }
}

// MARK: - App Leftovers review

/// The App Leftovers detail screen: a multi-select list of orphaned support-file
/// groups (one per uninstalled app's bundle ID), with a pinned Move to Trash
/// bar. Removal is opt-in and restorable (Trash).
struct AppLeftoversReviewView: View {
    let groups: [LeftoverGroup]
    let isSelected: (LeftoverGroup) -> Bool
    let onToggle: (LeftoverGroup) -> Void
    let onSelectAll: () -> Void
    let onClear: () -> Void
    let isRemoving: Bool
    let canRemove: Bool
    let onRemove: () -> Void

    private var selected: [LeftoverGroup] { groups.filter(isSelected) }
    private var selectedBytes: Int64 { selected.reduce(Int64(0)) { $0 + $1.totalBytes } }
    private var allSelected: Bool { !groups.isEmpty && selected.count == groups.count }

    var body: some View {
        if groups.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                selectAllBar
                Divider()
                List {
                    ForEach(groups) { group in
                        LeftoverRow(
                            group: group,
                            isSelected: isSelected(group),
                            onToggle: { onToggle(group) }
                        )
                        .accessibilityIdentifier("applications.leftovers.row.\(group.bundleID)")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                Divider()
                removeBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("applications.leftovers")
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
                    comment: "Toggle that selects/deselects every leftover group."
                ))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("applications.leftovers.selectAll")
            Spacer()
            Text(headerCountText)
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
                comment: "Button that moves the selected leftover files to the Trash."
            ), action: onRemove)
                .buttonStyle(.borderedProminent)
                .disabled(!canRemove)
                .accessibilityIdentifier("applications.leftovers.remove")
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(String(
                localized: "No app leftovers",
                comment: "Empty state on the App Leftovers review."
            ))
            .font(.title3.weight(.semibold))
            Text(String(
                localized: "No support files from uninstalled apps were found.",
                comment: "Empty-state detail on the App Leftovers review."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.leftovers.empty")
    }

    private var headerCountText: String {
        let total = smartScanByteFormatter.string(fromByteCount: groups.reduce(Int64(0)) { $0 + $1.totalBytes })
        let format = String(
            localized: "%lld apps · %@",
            comment: "App Leftovers header count; %lld is the orphaned-app count, %@ the total size."
        )
        return String.localizedStringWithFormat(format, Int64(groups.count), total)
    }

    private var selectionSummary: String {
        let size = smartScanByteFormatter.string(fromByteCount: selectedBytes)
        let format = String(
            localized: "%lld selected · %@",
            comment: "App Leftovers remove-bar summary; %lld is the selected count, %@ the selected size."
        )
        return String.localizedStringWithFormat(format, Int64(selected.count), size)
    }
}

/// One leftover-group row: a checkbox, a folder badge, the derived app name,
/// the bundle ID and file count, and the reclaimable size.
private struct LeftoverRow: View {
    let group: LeftoverGroup
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(systemName: "folder.badge.minus")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(smartScanByteFormatter.string(fromByteCount: group.totalBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let format = String(
            localized: "%1$@ · %2$lld items",
            comment: "Leftover row subtitle; %1$@ is the bundle ID, %2$lld the file count."
        )
        return String.localizedStringWithFormat(format, group.bundleID, Int64(group.urls.count))
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
