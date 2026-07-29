// ApplicationsUninstallerPane.swift
// The Applications Manager's Uninstaller pane: the facet column plus the app list, or a single app's associated-files detail.

import SwiftUI

/// The Uninstaller pane — the facet column plus the app list (or an app's
/// associated-files detail). Extracted from `ApplicationsManagerView` so a
/// checkbox toggle re-renders only this pane, not the whole manager. `facet`,
/// the drill-in, and the memoized list are owned by the parent (via bindings) so
/// they persist across pane switches; the batch metrics preload stays on the
/// parent, this pane just reads the resulting caches.
struct UninstallerPaneView: View {
    let uninstallerViewModel: AppUninstallerViewModel
    let homebrewViewModel: HomebrewViewModel
    let result: ApplicationsScanResult
    let iconCache: AppIconCache
    let search: String
    let sort: AppManagerSort
    @Binding var facet: AppManagerFacet
    @Binding var inspectingAppID: AppInfo.ID?
    @Binding var displayedApps: [AppInfo]
    @Binding var homebrewSelection: Set<BrewPackage.ID>

    /// Confirmation for the single app open in the chevron detail.
    @State private var showSingleUninstallConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            middleColumn.frame(width: 320)
            Divider().opacity(0.4)
            rightColumn.frame(maxWidth: .infinity)
        }
        .alert(singleUninstallConfirmationTitle, isPresented: $showSingleUninstallConfirmation) {
            Button(String(localized: "Cancel", comment: "Cancel button on the uninstall confirmation."), role: .cancel) {}
            Button(String(localized: "Uninstall", comment: "Confirm single-app uninstall."), role: .destructive) {
                Task { await uninstallerViewModel.uninstall() }
            }
        } message: {
            Text(singleUninstallConfirmationMessage)
        }
    }

    // MARK: Middle (facets)

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Uninstaller", comment: "Uninstaller pane title."),
                description: String(localized: "Correctly remove entire applications with all of the related files.", comment: "Uninstaller pane description.")
            )
            ScrollView { facets.padding(8) }
        }
    }

    private var facets: some View {
        let apps = uninstallerViewModel.apps
        let stores = ApplicationsManagerModel.storeCounts(apps: apps)
        let vendors = ApplicationsManagerModel.vendorCounts(apps: apps)
        return VStack(spacing: 4) {
            facetRow(.all, String(localized: "All Applications", comment: "Uninstaller facet."), apps.count)
            facetRow(.unused, String(localized: "Unused", comment: "Uninstaller facet."), unusedIDs.count)
            facetRow(.suspicious, String(localized: "Suspicious", comment: "Uninstaller facet."), 0)
            facetRow(.selected, String(localized: "Selected", comment: "Uninstaller facet."), uninstallerViewModel.uninstallSelection.count)

            ApplicationsManagerFacetSectionHeader(title: String(localized: "Stores", comment: "Uninstaller facet group header."))
            facetRow(.store(isAppStore: true), String(localized: "App Store", comment: "Uninstaller store facet."), stores.appStore)
            facetRow(.store(isAppStore: false), String(localized: "Other", comment: "Uninstaller store facet."), stores.other)
            facetRow(.homebrew, String(localized: "Homebrew", comment: "Uninstaller store facet."), homebrewViewModel.inventory.count)
                .accessibilityIdentifier("applications.manager.uninstaller.facet.homebrew")

            if !vendors.isEmpty {
                ApplicationsManagerFacetSectionHeader(title: String(localized: "Vendors", comment: "Uninstaller facet group header."))
                ForEach(vendors, id: \.vendor) { entry in
                    facetRow(.vendor(entry.vendor), entry.vendor.title, entry.count)
                }
            }
        }
    }

    private func facetRow(_ target: AppManagerFacet, _ label: String, _ count: Int) -> some View {
        ApplicationsManagerFacetRow(label: label, count: count, selected: facet == target) {
            facet = target
            inspectingAppID = nil
        }
    }

    /// `AppInfo.ID` (bundle-URL path) of every app the scan flagged as unused.
    private var unusedIDs: Set<AppInfo.ID> {
        Set(result.unusedApps.map { $0.app.id })
    }

    private var rightPaneTitle: String {
        switch facet {
        case .all:              return String(localized: "All Applications", comment: "Uninstaller right pane title.")
        case .unused:           return String(localized: "Unused", comment: "Uninstaller right pane title.")
        case .suspicious:       return String(localized: "Suspicious", comment: "Uninstaller right pane title.")
        case .selected:         return String(localized: "Selected", comment: "Uninstaller right pane title.")
        case .store(true):      return String(localized: "App Store", comment: "Uninstaller right pane title.")
        case .store(false):     return String(localized: "Other", comment: "Uninstaller right pane title.")
        case .vendor(let v):    return v.title
        case .homebrew:         return String(localized: "Homebrew", comment: "Uninstaller right pane title.")
        }
    }

    private var rightPaneDescription: String {
        switch facet {
        case .all:              return String(localized: "Every app installed on this Mac.", comment: "Uninstaller right pane description.")
        case .unused:           return String(localized: "Apps you haven't opened recently.", comment: "Uninstaller right pane description.")
        case .suspicious:       return String(localized: "Apps flagged as potentially unwanted.", comment: "Uninstaller right pane description.")
        case .selected:         return String(localized: "Apps you've marked for removal.", comment: "Uninstaller right pane description.")
        case .store(true):      return String(localized: "Apps installed from the Mac App Store.", comment: "Uninstaller right pane description.")
        case .store(false):     return String(localized: "Apps installed outside the Mac App Store.", comment: "Uninstaller right pane description.")
        case .vendor(let v):    return String(localized: "Apps from \(v.title).", comment: "Uninstaller right pane description for a vendor.")
        case .homebrew:         return String(localized: "Packages installed through Homebrew.", comment: "Uninstaller right pane description.")
        }
    }

    // MARK: Right (list / detail)

    @ViewBuilder
    private var rightColumn: some View {
        if facet == .homebrew {
            HomebrewUninstallContent(
                viewModel: homebrewViewModel,
                search: search,
                selection: $homebrewSelection
            )
        } else if let id = inspectingAppID {
            appDetail(id)
        } else if uninstallerViewModel.apps.isEmpty, uninstallerViewModel.phase == .loading {
            ApplicationsManagerLoadingPane()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ApplicationsManagerPaneHeader(title: rightPaneTitle, description: rightPaneDescription)
                list
            }
        }
    }

    /// Recomputes the memoized `displayedApps`. Called from the list's
    /// `onAppear` and the `onChange` hooks below — never from `body` — so the
    /// filter + sort runs only when an input that changes the list changes, not
    /// on every re-render (e.g. a checkbox toggle, which only needs the tapped
    /// row to redraw).
    private func recompute() {
        let filtered = ApplicationsManagerModel.filter(
            uninstallerViewModel.apps,
            facet: facet,
            search: search,
            unusedIDs: unusedIDs,
            selectedIDs: uninstallerViewModel.uninstallSelection
        )
        displayedApps = ApplicationsManagerModel.sort(
            filtered,
            by: sort,
            sizes: uninstallerViewModel.listSizes
        )
    }

    @ViewBuilder
    private var list: some View {
        // The recompute hooks stay attached to the outer Group so they fire in
        // both branches — otherwise an initially empty `displayedApps` would
        // pin the empty state and never recompute into the list.
        Group {
            if displayedApps.isEmpty {
                ApplicationsManagerEmptyState(
                    icon: "checkmark.seal.fill",
                    title: String(localized: "Uninstaller", comment: "Uninstaller empty-state title."),
                    detail: String(localized: "There are no items to clean or fix in this area.\nEverything is in order.", comment: "Uninstaller empty-state detail.")
                )
                .accessibilityIdentifier("applications.manager.uninstaller.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(displayedApps) { app in
                            appRow(app)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                .accessibilityIdentifier("applications.manager.uninstaller.list")
            }
        }
        .onAppear { recompute() }
        .onChange(of: facet) { _, _ in recompute() }
        .onChange(of: search) { _, _ in recompute() }
        .onChange(of: sort) { _, _ in recompute() }
        .onChange(of: uninstallerViewModel.apps.map(\.id)) { _, _ in recompute() }
        // The measured metrics land asynchronously; recompute the order once
        // when they do so a size/date sort settles to its final arrangement.
        .onChange(of: uninstallerViewModel.listMetricsRevision) { _, _ in recompute() }
        // Selection only changes the visible list under the Selected facet;
        // under every other facet a toggle leaves the list untouched, so the
        // expensive recompute is skipped.
        .onChange(of: uninstallerViewModel.uninstallSelection) { _, _ in
            if facet == .selected { recompute() }
        }
    }

    private func appRow(_ app: AppInfo) -> some View {
        HStack(spacing: 12) {
            ApplicationsManagerCheckbox(selected: uninstallerViewModel.isInUninstallSelection(app.id)) {
                uninstallerViewModel.toggleUninstallSelection(app.id)
            }
            Image(nsImage: iconCache.icon(for: app.bundleURL))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let version = app.version {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            SmartInsightsSparkle(itemTitle: app.name, accent: ApplicationsManagerChrome.accent, topic: .application)
            Text(dateText(app.lastUsedDate))
                .font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
            Text(sizeText(uninstallerViewModel.listSizes[app.id]))
                .font(.callout.weight(.semibold)).frame(width: 72, alignment: .trailing)
            Button {
                inspectingAppID = app.id
                uninstallerViewModel.select(app.id)
            } label: {
                Image(systemName: "chevron.right").foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("applications.manager.uninstaller.detail.\(app.bundleID)")
        }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("applications.manager.uninstaller.row.\(app.bundleID)")
    }

    private func appDetail(_ id: AppInfo.ID) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    inspectingAppID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").foregroundStyle(.tint)
                        Text(String(localized: "All Applications", comment: "Back to the full uninstaller list."))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("applications.manager.uninstaller.detail.back")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.4)
            AppUninstallerDetailPane(
                app: uninstallerViewModel.selectedApp,
                bundleSize: uninstallerViewModel.selectedAppBundleSize,
                isLoadingAssociatedFiles: uninstallerViewModel.isLoadingAssociatedFiles,
                groupedFiles: uninstallerViewModel.associatedFilesByCategory,
                totalReclaimableSize: uninstallerViewModel.totalReclaimableSize,
                canUninstall: uninstallerViewModel.canUninstallSelectedApp,
                onUninstall: { showSingleUninstallConfirmation = true },
                iconCache: iconCache
            )
        }
        .onChange(of: uninstallerViewModel.apps.map(\.id)) { _, ids in
            // The app was uninstalled from the detail — return to the list.
            if let id = inspectingAppID, !ids.contains(id) { inspectingAppID = nil }
        }
    }

    private var singleUninstallConfirmationTitle: String {
        guard let app = uninstallerViewModel.selectedApp else {
            return String(localized: "Move this app and its data to Trash?", comment: "Single uninstall confirmation title fallback.")
        }
        let format = String(localized: "Move %@ and its data to Trash?", comment: "Single uninstall confirmation title; %@ is the app name.")
        return String.localizedStringWithFormat(format, app.name)
    }

    private var singleUninstallConfirmationMessage: String {
        String(localized: "The application and its associated files will be moved to the Trash. You can restore them until you empty it.", comment: "Single uninstall confirmation message.")
    }

    private func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return formattedFileBytes(bytes)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
