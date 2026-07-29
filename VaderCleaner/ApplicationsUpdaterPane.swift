// ApplicationsUpdaterPane.swift
// The Applications Manager's Updater pane: the facet column plus the available-updates list.

import SwiftUI

/// Middle-pane facet for the Updater pane.
enum UpdaterFacet: Hashable {
    case all
    case selected
    case store(isAppStore: Bool)
    /// Outdated Homebrew packages — a parallel list under the Stores group,
    /// upgraded through `brew upgrade` rather than opening an update URL.
    case homebrew
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
            facetRow(.store(isAppStore: true), String(localized: "App Store", comment: "Updater store facet."), appStore)
            facetRow(.store(isAppStore: false), String(localized: "Other", comment: "Updater store facet."), updates.count - appStore)
            facetRow(.homebrew, String(localized: "Homebrew", comment: "Updater store facet."), homebrewViewModel.availableUpdateCount)
                .accessibilityIdentifier("applications.manager.updater.facet.homebrew")
        }
    }

    private func facetRow(_ target: UpdaterFacet, _ label: String, _ count: Int) -> some View {
        ApplicationsManagerFacetRow(label: label, count: count, selected: facet == target) {
            facet = target
        }
    }

    private var rightPaneTitle: String {
        switch facet {
        case .all:              return String(localized: "All Updates", comment: "Updater right pane title.")
        case .selected:         return String(localized: "Selected", comment: "Updater right pane title.")
        case .store(true):      return String(localized: "App Store", comment: "Updater right pane title.")
        case .store(false):     return String(localized: "Other", comment: "Updater right pane title.")
        case .homebrew:         return String(localized: "Homebrew", comment: "Updater right pane title.")
        }
    }

    private var rightPaneDescription: String {
        switch facet {
        case .all:              return String(localized: "Apps with new versions available.", comment: "Updater right pane description.")
        case .selected:         return String(localized: "Updates you've chosen to install.", comment: "Updater right pane description.")
        case .store(true):      return String(localized: "Updates available through the Mac App Store.", comment: "Updater right pane description.")
        case .store(false):     return String(localized: "Updates available from developer websites.", comment: "Updater right pane description.")
        case .homebrew:         return String(localized: "Homebrew packages with a newer version.", comment: "Updater right pane description.")
        }
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
                list
            }
        }
    }

    private func recompute() {
        displayed = updaterViewModel.availableUpdates.filter { info in
            let matchesFacet: Bool
            switch facet {
            case .all:                    matchesFacet = true
            case .selected:               matchesFacet = selection.contains(info.id)
            case .store(let isAppStore):  matchesFacet = (info.source == .appStore) == isAppStore
            // Homebrew is a separate list, not an app-update filter.
            case .homebrew:               matchesFacet = false
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
            }
            Spacer(minLength: 8)
            SmartInsightsSparkle(itemTitle: info.appName, accent: ApplicationsManagerChrome.accent, topic: .application)
            Text(info.source == .appStore
                 ? String(localized: "App Store", comment: "Update source label.")
                 : String(localized: "Web", comment: "Update source label."))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("applications.manager.updater.row.\(info.bundleID)")
    }

    private func versionTransition(_ info: UpdateInfo) -> String {
        let format = String(localized: "%1$@ → %2$@", comment: "Update row version change; installed → latest.")
        return String.localizedStringWithFormat(format, info.installedVersion, info.latestVersion)
    }
}
