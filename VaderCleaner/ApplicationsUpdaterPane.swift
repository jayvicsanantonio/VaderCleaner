// ApplicationsUpdaterPane.swift
// The Applications Manager's Updater pane: the facet column plus the available-updates list.

import SwiftUI

/// Middle-pane facet for the Updater pane.
enum UpdaterFacet: Hashable {
    case all
    case selected
    /// Keyed by the channel itself rather than an "is App Store" flag, so
    /// the facet, its title, and the row badge all read their label from
    /// one place and a future channel can't inherit another's name.
    case store(UpdateSource)
    /// Outdated Homebrew packages — a parallel list under the Stores group,
    /// upgraded through `brew upgrade` rather than opening an update URL.
    case homebrew
    /// Apps installed by a Homebrew cask. Upgraded from the Homebrew
    /// facet — offering them a download would overwrite a managed install.
    case homebrewManaged
    /// Apps that keep themselves current through a bundled updater. Listed
    /// so the coverage headline is accountable, not as work to do.
    case selfUpdating
    /// Apps with no detectable update mechanism — the blind spot the
    /// update list alone would silently imply doesn't exist.
    case unmonitored
    /// Updates the user declined. Listed so the choice stays reversible.
    case skipped
}

/// The Updater pane — the facet column plus the available-updates list.
/// Extracted from `ApplicationsManagerView`; the facet, selection, and memoized
/// list are owned by the parent (the footer's Update action reads the selection)
/// and passed in as bindings.
struct UpdaterPaneView: View {
    let updaterViewModel: AppUpdaterViewModel
    let homebrewViewModel: HomebrewViewModel
    let iconCache: AppIconCache
    let search: String
    @Binding var facet: UpdaterFacet
    @Binding var selection: Set<UpdateInfo.ID>
    @Binding var displayed: [UpdateInfo]
    @Binding var homebrewSelection: Set<BrewOutdatedItem.ID>

    var body: some View {
        HStack(spacing: 0) {
            middleColumn.frame(width: 320)
            Divider().opacity(0.4)
            rightColumn.frame(maxWidth: .infinity)
        }
    }

    // MARK: Middle (facets)

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Updater", comment: "Updater pane title."),
                description: String(localized: "Keep your apps current with the latest fixes and features.", comment: "Updater pane description.")
            )
            ScrollView { facets.padding(8) }
        }
    }

    private var facets: some View {
        let updates = updaterViewModel.availableUpdates
        let appStore = updates.filter { $0.source == .appStore }.count
        return VStack(spacing: 4) {
            facetRow(.all, String(localized: "All Updates", comment: "Updater facet."), updates.count)
            facetRow(.selected, String(localized: "Selected", comment: "Updater facet."), selection.count)

            ApplicationsManagerFacetSectionHeader(title: String(localized: "Stores", comment: "Updater facet group header."))
            facetRow(.store(.appStore), sourceLabel(.appStore), appStore)
            facetRow(.store(.sparkle), sourceLabel(.sparkle), updates.count - appStore)
            facetRow(.homebrew, String(localized: "Homebrew", comment: "Updater store facet."), homebrewViewModel.availableUpdateCount)
                .accessibilityIdentifier("applications.manager.updater.facet.homebrew")

            ApplicationsManagerFacetSectionHeader(title: String(localized: "Coverage", comment: "Updater facet group header."))
            facetRow(.homebrewManaged, String(localized: "Managed by Homebrew", comment: "Updater coverage facet."), coverage.homebrewManaged.count)
                .accessibilityIdentifier("applications.manager.updater.facet.homebrewmanaged")
            facetRow(.selfUpdating, String(localized: "Self-updating", comment: "Updater coverage facet."), coverage.selfUpdating.count)
                .accessibilityIdentifier("applications.manager.updater.facet.selfupdating")
            facetRow(.unmonitored, String(localized: "Not monitored", comment: "Updater coverage facet."), coverage.unmonitored.count)
                .accessibilityIdentifier("applications.manager.updater.facet.unmonitored")
            facetRow(.skipped, String(localized: "Skipped", comment: "Updater coverage facet."), updaterViewModel.skippedUpdates.count)
                .accessibilityIdentifier("applications.manager.updater.facet.skipped")
        }
    }

    private var coverage: UpdateCoverage { updaterViewModel.coverage }

    private func facetRow(_ target: UpdaterFacet, _ label: String, _ count: Int) -> some View {
        ApplicationsManagerFacetRow(label: label, count: count, selected: facet == target) {
            facet = target
        }
    }

    private var rightPaneTitle: String {
        switch facet {
        case .all:              return String(localized: "All Updates", comment: "Updater right pane title.")
        case .selected:         return String(localized: "Selected", comment: "Updater right pane title.")
        case .store(let source): return sourceLabel(source)
        case .homebrew:         return String(localized: "Homebrew", comment: "Updater right pane title.")
        case .homebrewManaged:  return String(localized: "Managed by Homebrew", comment: "Updater right pane title.")
        case .selfUpdating:     return String(localized: "Self-updating", comment: "Updater right pane title.")
        case .unmonitored:      return String(localized: "Not monitored", comment: "Updater right pane title.")
        case .skipped:          return String(localized: "Skipped", comment: "Updater right pane title.")
        }
    }

    private var rightPaneDescription: String {
        switch facet {
        case .all:              return coverageSummary
        case .selected:         return String(localized: "Updates you've chosen to install.", comment: "Updater right pane description.")
        case .store(.appStore): return String(localized: "Updates available through the Mac App Store.", comment: "Updater right pane description.")
        case .store(.sparkle):  return String(localized: "Updates downloaded from the developer's website.", comment: "Updater right pane description.")
        case .store(.homebrew): return String(localized: "Updates Homebrew applies in place.", comment: "Updater right pane description.")
        case .homebrew:         return String(localized: "Homebrew packages with a newer version.", comment: "Updater right pane description.")
        case .homebrewManaged:  return String(localized: "Homebrew installed these apps and upgrades them in place.", comment: "Updater right pane description.")
        case .selfUpdating:     return String(localized: "These apps update themselves, so we don't check them.", comment: "Updater right pane description.")
        case .unmonitored:      return String(localized: "We found no way to check these apps for updates.", comment: "Updater right pane description.")
        case .skipped:          return String(localized: "Versions you chose not to install. A newer release will appear again.", comment: "Updater right pane description.")
        }
    }

    /// The All Updates header states what was inspected, not just what was
    /// found. A bare "apps with new versions" list reads as "everything
    /// else is current", which is false whenever most installed apps
    /// publish no feed we can query.
    private var coverageSummary: String {
        let base = String(localized: "Apps with new versions available.", comment: "Updater right pane description.")
        guard coverage.total > 0 else { return base }
        let format = String(localized: "Checked %1$lld of %2$lld apps.", comment: "Updater coverage headline; apps reached out of apps installed.")
        let checked = String.localizedStringWithFormat(format, Int64(coverage.checked), Int64(coverage.total))
        return "\(base)  ·  \(checked)"
    }

    // MARK: Right (list)

    @ViewBuilder
    private var rightColumn: some View {
        if facet == .homebrew {
            HomebrewOutdatedContent(
                viewModel: homebrewViewModel,
                search: search,
                selection: $homebrewSelection
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ApplicationsManagerPaneHeader(title: rightPaneTitle, description: rightPaneDescription)
                switch facet {
                case .skipped:
                    skippedList
                case .homebrewManaged:
                    coverageList(
                        coverage.homebrewManaged.map { ($0.app, homebrewDetail($0.token)) },
                        emptyDetail: String(localized: "Homebrew hasn't installed any of your apps.", comment: "Homebrew-managed empty-state detail."),
                        identifier: "homebrewmanaged"
                    )
                case .selfUpdating:
                    coverageList(
                        coverage.selfUpdating.map { ($0.app, selfUpdaterDetail($0.updater)) },
                        emptyDetail: String(localized: "No installed app ships its own updater.", comment: "Self-updating empty-state detail."),
                        identifier: "selfupdating"
                    )
                case .unmonitored:
                    coverageList(
                        coverage.unmonitored.map { ($0, String(localized: "No update feed detected", comment: "Unmonitored app row detail.")) },
                        emptyDetail: String(localized: "Every installed app has a way to stay current.", comment: "Not-monitored empty-state detail."),
                        identifier: "unmonitored"
                    )
                default:
                    list
                }
            }
        }
    }

    /// Declined updates, each offering its way back. Reuses the update
    /// row so a skipped entry looks like what it is — an update, set
    /// aside — rather than a different kind of thing.
    @ViewBuilder
    private var skippedList: some View {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = trimmed.isEmpty
            ? updaterViewModel.skippedUpdates
            : updaterViewModel.skippedUpdates.filter { $0.appName.localizedCaseInsensitiveContains(trimmed) }
        if entries.isEmpty {
            ApplicationsManagerEmptyState(
                icon: "clock.arrow.circlepath",
                title: rightPaneTitle,
                detail: String(localized: "You haven't skipped any updates.", comment: "Skipped empty-state detail.")
            )
            .accessibilityIdentifier("applications.manager.updater.skipped.empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(entries) { info in
                        row(info)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .accessibilityIdentifier("applications.manager.updater.skipped.list")
        }
    }

    /// Rows for the coverage facets: an app and why it wasn't checked.
    /// No checkbox — there is nothing here to act on, which is the point.
    @ViewBuilder
    private func coverageList(
        _ entries: [(app: AppInfo, detail: String)],
        emptyDetail: String,
        identifier: String
    ) -> some View {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty
            ? entries
            : entries.filter { $0.app.name.localizedCaseInsensitiveContains(trimmed) }
        if filtered.isEmpty {
            ApplicationsManagerEmptyState(
                icon: "checkmark.shield",
                title: rightPaneTitle,
                detail: emptyDetail
            )
            .accessibilityIdentifier("applications.manager.updater.\(identifier).empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filtered, id: \.app.id) { entry in
                        coverageRow(entry.app, detail: entry.detail)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .accessibilityIdentifier("applications.manager.updater.\(identifier).list")
        }
    }

    private func coverageRow(_ app: AppInfo, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: iconCache.icon(for: app.bundleURL))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(app.version ?? String(localized: "Unknown", comment: "Placeholder for an app with no version string."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("applications.manager.updater.coverage.row.\(app.bundleID)")
    }

    private func homebrewDetail(_ token: String) -> String {
        let format = String(localized: "Upgrade with Homebrew (%@)", comment: "Homebrew-managed row detail; the cask token.")
        return String.localizedStringWithFormat(format, token)
    }

    private func selfUpdaterDetail(_ updater: SelfUpdater) -> String {
        switch updater {
        case .keystone:
            return String(localized: "Updates through Google Software Update", comment: "Self-updating row detail for Keystone apps.")
        case .squirrel:
            return String(localized: "Updates itself in the background", comment: "Self-updating row detail for Squirrel apps.")
        }
    }

    private func recompute() {
        displayed = updaterViewModel.availableUpdates.filter { info in
            let matchesFacet: Bool
            switch facet {
            case .all:                    matchesFacet = true
            case .selected:               matchesFacet = selection.contains(info.id)
            case .store(let source):      matchesFacet = info.source == source
            // Homebrew and the coverage facets are separate lists, not
            // filters over the available updates.
            case .homebrew, .homebrewManaged, .selfUpdating, .unmonitored, .skipped:
                matchesFacet = false
            }
            guard matchesFacet else { return false }
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || info.appName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    @ViewBuilder
    private var list: some View {
        // The recompute hooks stay attached to the outer Group so they fire in
        // both branches — otherwise an initially empty `displayed` would pin the
        // empty state and never recompute into the list.
        Group {
            if displayed.isEmpty {
                ApplicationsManagerEmptyState(
                    icon: "arrow.down.circle",
                    title: String(localized: "Updater", comment: "Updater empty-state title."),
                    detail: String(localized: "There are no items to clean or fix in this area.\nEverything is in order.", comment: "Updater empty-state detail.")
                )
                .accessibilityIdentifier("applications.manager.updater.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(displayed) { info in
                            row(info)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
                .accessibilityIdentifier("applications.manager.updater.list")
            }
        }
        .onAppear { recompute() }
        .onChange(of: facet) { _, _ in recompute() }
        .onChange(of: search) { _, _ in recompute() }
        .onChange(of: updaterViewModel.availableUpdates.map(\.id)) { _, _ in recompute() }
        // The selection only changes the visible list under the Selected facet.
        .onChange(of: selection) { _, _ in
            if facet == .selected { recompute() }
        }
    }

    private func row(_ info: UpdateInfo) -> some View {
        HStack(spacing: 12) {
            ApplicationsManagerCheckbox(selected: selection.contains(info.id)) {
                if selection.contains(info.id) { selection.remove(info.id) } else { selection.insert(info.id) }
            }
            Image(nsImage: iconCache.icon(for: info.bundleURL))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.appName).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(versionTransition(info)).font(.caption).foregroundStyle(.secondary)
                // "12.8 → 12.9" says nothing about whether the update
                // matters. The summary is already length-capped upstream;
                // the tooltip carries whatever the two lines cut off.
                if let notes = info.releaseNotes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .help(notes)
                        .accessibilityIdentifier("applications.manager.updater.notes.\(info.bundleID)")
                }
            }
            Spacer(minLength: 8)
            SmartInsightsSparkle(itemTitle: info.appName, accent: ApplicationsManagerChrome.accent, topic: .application)
            Text(sourceLabel(info.source))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("applications.manager.updater.row.\(info.bundleID)")
        // A context menu rather than a row control: skipping is an
        // occasional choice, and a per-row button would compete with the
        // checkbox that drives the footer's Update action.
        .contextMenu {
            if facet == .skipped {
                Button(String(localized: "Stop Skipping", comment: "Restores a skipped update to the list.")) {
                    updaterViewModel.clearSkip(forBundleID: info.bundleID)
                }
            } else {
                Button(String(localized: "Skip This Version", comment: "Declines one version of an update.")) {
                    updaterViewModel.skip(info)
                    selection.remove(info.id)
                }
            }
        }
    }

    /// The single naming authority for an update channel — used by the
    /// facet row, the right-pane title, and the row badge, which
    /// previously called the same set "Other" and "Web" respectively.
    ///
    /// Exhaustive rather than an `== .appStore` ternary: a fallback would
    /// silently label any future channel "Web", asserting a direct
    /// download for something that may not have one.
    private func sourceLabel(_ source: UpdateSource) -> String {
        switch source {
        case .appStore: return String(localized: "App Store", comment: "Update source label.")
        case .sparkle:  return String(localized: "Web", comment: "Update source label.")
        case .homebrew: return String(localized: "Homebrew", comment: "Update source label.")
        }
    }

    private func versionTransition(_ info: UpdateInfo) -> String {
        let format = String(localized: "%1$@ → %2$@", comment: "Update row version change; installed → latest.")
        return String.localizedStringWithFormat(format, info.installedVersion, info.latestVersion)
    }
}
