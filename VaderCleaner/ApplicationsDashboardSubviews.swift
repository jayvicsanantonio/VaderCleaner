// ApplicationsDashboardSubviews.swift
// Post-scan dashboard for the Applications section — the "N apps found" header, the summary card grid, and the progress / failed states.

import SwiftUI

// MARK: - Dashboard

/// The Applications landing surface after a scan: a headline count, a "Manage
/// My Applications" affordance, and the summary cards in an adaptive grid —
/// mirroring the Performance dashboard's card layout.
struct ApplicationsDashboardView: View {
    let result: ApplicationsScanResult
    var iconCache: AppIconCache
    /// Section accent, used to tint any reassurance backfill cards.
    let accent: Color
    let onOpenManage: () -> Void
    let onOpenInstallationFiles: () -> Void
    let onOpenUnsupported: () -> Void
    let onOpenUnused: () -> Void
    let onOpenUpdates: () -> Void
    let onOpenLeftovers: () -> Void
    /// One-click removal for the App Leftovers card's Remove button — selects
    /// every leftover group and moves it to the Trash.
    let onRemoveLeftovers: () -> Void

    /// Total on-disk size of the unused apps, summed off-main for the Unused
    /// card's "they use N of space" detail. `nil` until the walk returns.
    @State private var unusedTotalBytes: Int64?

    var body: some View {
        VStack(spacing: 18) {
            header
            // The grid stays flexible (it absorbs any height squeeze) so the
            // hero keeps its standard size instead of being compressed.
            cardLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.dashboard")
        .task(id: result.unusedApps.map(\.id)) {
            // Preload the unused apps' icons for the Unused card's icon cluster
            // and sum their on-disk sizes off-main for its detail line.
            let urls = result.unusedApps.map { $0.app.bundleURL }
            await iconCache.preloadIcons(for: urls)
            unusedTotalBytes = await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                return urls.reduce(Int64(0)) { $0 + DefaultAppDiscovery.bundleSize(at: $1, fileManager: fileManager) }
            }.value
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("applications")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 140, maxHeight: 140)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(installedCountText)
                    .font(.title.weight(.semibold))
                    .accessibilityIdentifier("applications.installedCount")
                Text(String(
                    localized: "Use quick recommendations or manage them by hand.",
                    comment: "Applications dashboard subheadline beneath the installed-app count."
                ))
                .font(.title3)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)

            Button(action: onOpenManage) {
                Text(String(
                    localized: "Manage My Applications",
                    comment: "Button that opens the full installed-apps management (uninstaller) list."
                ))
                .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("applications.manageMyApplications")
        }
    }

    /// One dashboard card's content, built as data so the layout can render the
    /// lead recommendation as a tall left card and stack the rest in a right
    /// column — matching the reference dashboard.
    private struct CardSpec: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: ApplicationsCardIcon
        let primaryLabel: String
        let primaryAction: () -> Void
        /// Optional second action, rendered as a bordered button to the left of
        /// the prominent primary (the App Leftovers card's Review).
        var secondaryLabel: String? = nil
        var secondaryAction: (() -> Void)? = nil
    }

    private var reviewLabel: String {
        String(localized: "Review", comment: "Applications card action that opens a review list.")
    }

    private var removeLabel: String {
        String(localized: "Remove", comment: "Applications card action that removes the finding directly.")
    }

    private func spec(for recommendation: ApplicationsScanResult.Recommendation) -> CardSpec {
        switch recommendation {
        case .unsupported:
            return CardSpec(id: "applications.card.unsupported", title: unsupportedTitle,
                            detail: unsupportedDetail, icon: .symbol("exclamationmark.triangle.fill"),
                            primaryLabel: reviewLabel, primaryAction: onOpenUnsupported)
        case .unused:
            return CardSpec(id: "applications.card.unused", title: unusedTitle,
                            detail: unusedDetail,
                            icon: .appIcons(Array(result.unusedApps.prefix(3).map { $0.app.bundleURL })),
                            primaryLabel: reviewLabel, primaryAction: onOpenUnused)
        case .updates:
            return CardSpec(id: "applications.card.updates", title: updatesTitle,
                            detail: updatesDetail, icon: .symbol("arrow.down.circle.fill"),
                            primaryLabel: updateLabel, primaryAction: onOpenUpdates)
        case .leftovers:
            // Review (bordered) + Remove (prominent), matching the reference card.
            return CardSpec(id: "applications.card.leftovers", title: leftoversTitle,
                            detail: leftoversDetail, icon: .asset("appLeftovers"),
                            primaryLabel: removeLabel, primaryAction: onRemoveLeftovers,
                            secondaryLabel: reviewLabel, secondaryAction: onOpenLeftovers)
        case .installationFiles:
            return CardSpec(id: "applications.card.installationFiles", title: installationFilesTitle,
                            detail: installationFilesDetail, icon: .asset("installerDmg"),
                            primaryLabel: reviewLabel, primaryAction: onOpenInstallationFiles)
        }
    }

    /// The ranked 2–4 cards this scan warrants, most actionable first.
    private var tiles: [ApplicationsDashboardTile] {
        result.recommendedTiles()
    }

    /// The reference layout: the lead card is a tall card on the left, and the
    /// remaining cards sit in a right-hand column packed into rows of two (an odd
    /// count leads with a single full-width row), mirroring the My Clutter
    /// dashboard. Capping the right column at rows of two keeps the grid bounded
    /// so it fills the pane without overflowing, however many cards there are.
    @ViewBuilder
    private var cardLayout: some View {
        let tiles = self.tiles
        if tiles.count <= 1 {
            if let only = tiles.first {
                card(only).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GlassEffectContainer(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    card(tiles[0])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    rightColumn(Array(tiles.dropFirst()))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The right-hand cards, packed into rows of at most two so the column never
    /// grows taller than the pane.
    private func rightColumn(_ tiles: [ApplicationsDashboardTile]) -> some View {
        VStack(spacing: 16) {
            ForEach(rows(of: tiles)) { row in
                HStack(spacing: 16) {
                    ForEach(row.tiles) { tile in
                        card(tile).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// One row of right-column cards.
    private struct CardRow: Identifiable {
        let id: Int
        let tiles: [ApplicationsDashboardTile]
    }

    /// Chunks the right-column cards into rows of two. An odd count leads with a
    /// single full-width row (matching My Clutter's "one then a pair" shape).
    private func rows(of tiles: [ApplicationsDashboardTile]) -> [CardRow] {
        var rows: [CardRow] = []
        var remaining = tiles
        if remaining.count % 2 == 1 {
            rows.append(CardRow(id: 0, tiles: [remaining.removeFirst()]))
        }
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(2))
            remaining.removeFirst(chunk.count)
            rows.append(CardRow(id: rows.count, tiles: chunk))
        }
        return rows
    }

    /// Renders one ranked tile with its recommendation card, or a reassurance
    /// backfill.
    @ViewBuilder
    private func card(_ tile: ApplicationsDashboardTile) -> some View {
        switch tile {
        case .recommendation(let recommendation):
            let spec = spec(for: recommendation)
            ApplicationsDashboardCard(
                title: spec.title,
                detail: spec.detail,
                icon: spec.icon,
                primaryLabel: spec.primaryLabel,
                primaryAction: spec.primaryAction,
                secondaryLabel: spec.secondaryLabel,
                secondaryAction: spec.secondaryAction,
                identifier: spec.id,
                iconCache: iconCache
            )
        case .reassurance(let content):
            ReassuranceCard(content: content, accent: accent)
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

    private var updateLabel: String {
        String(localized: "Update", comment: "Applications Updates card action that opens the Updater pane.")
    }

    private var installationFilesTitle: String {
        if result.installationFilesCount == 0 {
            return String(
                localized: "No Installation Files",
                comment: "Applications Installation Files card title when none are found."
            )
        }
        let format = String(
            localized: "%@ of Installation Files Found",
            comment: "Applications Installation Files card title; %@ is the reclaimable size."
        )
        return String.localizedStringWithFormat(format, smartScanByteFormatter.string(fromByteCount: result.installationFilesTotalBytes))
    }

    private var installationFilesDetail: String {
        if result.installationFilesCount == 0 {
            return String(
                localized: "No leftover disk images or installer packages in your Downloads or Desktop.",
                comment: "Applications Installation Files card detail when none are found."
            )
        }
        return String(
            localized: "DMGs and installers you no longer need.",
            comment: "Applications Installation Files card detail when some are found."
        )
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
            comment: "Applications Unused card title; %lld is the unused-app count."
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
        if let bytes = unusedTotalBytes {
            let format = String(
                localized: "You may not need these apps, but they use %@ of space in total.",
                comment: "Applications Unused card detail; %@ is the total on-disk size of the unused apps."
            )
            return String.localizedStringWithFormat(format, smartScanByteFormatter.string(fromByteCount: bytes))
        }
        return String(
            localized: "You may not need these apps. Remove the ones you no longer use.",
            comment: "Applications Unused card detail shown before the total size has been measured."
        )
    }

    private var updatesTitle: String {
        if result.updatesCount == 0 {
            return String(
                localized: "No Updates Available",
                comment: "Applications Updates card title when none are found."
            )
        }
        let format = String(
            localized: "%lld Updates Available",
            comment: "Applications Updates card title; %lld is the available-update count."
        )
        return String.localizedStringWithFormat(format, Int64(result.updatesCount))
    }

    private var updatesDetail: String {
        if result.updatesCount == 0 {
            return String(
                localized: "Every app is up to date.",
                comment: "Applications Updates card detail when none are found."
            )
        }
        return String(
            localized: "These apps have newer versions available. Update them to get the latest fixes.",
            comment: "Applications Updates card detail when some are found."
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
            localized: "%@ of App Leftovers Found",
            comment: "Applications Leftovers card title; %@ is the reclaimable size."
        )
        return String.localizedStringWithFormat(format, smartScanByteFormatter.string(fromByteCount: result.leftoversTotalBytes))
    }

    private var leftoversDetail: String {
        if result.leftoversCount == 0 {
            return String(
                localized: "No support files from uninstalled apps were found.",
                comment: "Applications Leftovers card detail when none are found."
            )
        }
        return String(
            localized: "Bits left behind by apps you've uninstalled.",
            comment: "Applications Leftovers card detail when some are found."
        )
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
            comment: "Applications Unsupported card title; %lld is the unsupported-app count."
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
/// radius as the Performance / Smart Scan dashboards so the app's card
/// surfaces stay consistent. Also reused by the Privacy dashboard's category
/// cards for the same reason.
struct ApplicationsCard: View {
    let title: String
    /// Short, emphasized magnitude (reclaimable size or item count) shown as the
    /// card's headline number beneath the title.
    let metric: String
    let detail: String
    let icon: String
    let actionLabel: String
    let identifier: String
    /// Hero cards render taller, matching the Performance dashboard's hero /
    /// standard `minHeight` (260 / 150) so the two dashboards share one look.
    let isHero: Bool
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
            Text(metric)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack {
                Spacer()
                Button(actionLabel, action: action)
                    .buttonStyle(.vaderProminent)
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: isHero ? 260 : 150, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Dashboard card (Applications)

/// How an Applications dashboard card illustrates its finding: a generated
/// raster tile (App Leftovers / installer DMG), a tinted SF Symbol, or a
/// cluster of the real app icons (the Unused card).
enum ApplicationsCardIcon {
    case asset(String)
    case symbol(String)
    case appIcons([URL])
}

/// A single Applications dashboard card in the reference layout: a title and
/// detail at the top with a top-right illustration, and a bottom action row.
/// The Unused card additionally shows a cluster of real app icons at the
/// bottom-left; the App Leftovers card shows a bordered Review plus a prominent
/// Remove. Distinct from `ApplicationsCard` (still used by the Privacy
/// dashboard) so that surface is left unchanged.
struct ApplicationsDashboardCard: View {
    let title: String
    let detail: String
    let icon: ApplicationsCardIcon
    let primaryLabel: String
    let primaryAction: () -> Void
    let secondaryLabel: String?
    let secondaryAction: (() -> Void)?
    let identifier: String
    var iconCache: AppIconCache

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                topRightIcon.frame(width: 52, height: 52)
            }
            // The Unused card fills its body with a centred cluster of the real
            // app icons; the others just push the action row to the bottom.
            if case .appIcons(let urls) = icon, !urls.isEmpty {
                Spacer(minLength: 12)
                appIconCluster(urls).frame(maxWidth: .infinity)
                Spacer(minLength: 12)
            } else {
                Spacer(minLength: 8)
            }
            HStack(spacing: 10) {
                Spacer()
                if let secondaryLabel, let secondaryAction {
                    Button(secondaryLabel, action: secondaryAction)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(identifier + ".secondary")
                }
                Button(primaryLabel, action: primaryAction)
                    .buttonStyle(.vaderProminent)
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var topRightIcon: some View {
        switch icon {
        case .asset(let name):
            Image(name).resizable().aspectRatio(contentMode: .fit)
        case .symbol(let name):
            Image(systemName: name)
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
                .padding(4)
        case .appIcons:
            // The Unused card illustrates with the icon cluster at the bottom.
            EmptyView()
        }
    }

    /// Overlapping real app icons for the Unused card, centred to fill the tall
    /// card body.
    private func appIconCluster(_ urls: [URL]) -> some View {
        HStack(spacing: -16) {
            ForEach(urls, id: \.self) { url in
                Image(nsImage: iconCache.icon(for: url))
                    .resizable()
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
        }
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
                .buttonStyle(.vaderProminent)
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
                .buttonStyle(.vaderProminent)
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
                .buttonStyle(.vaderProminent)
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
                .buttonStyle(.vaderProminent)
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
            ScanProgressIndicator()
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
