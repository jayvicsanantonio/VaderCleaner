// ApplicationsManagerView.swift
// The "Applications Manager" — a white-card, three-pane CleanMyMac-style surface (left nav → middle facets → right item list + footer action) modeled on the My Clutter Manager, hosting the Uninstaller, Updater, Extensions, and Leftovers panes.

import SwiftUI

/// Three-pane manager reached from the Applications dashboard's "Manage My
/// Applications" card and the cleanup cards' Review actions. The chrome (white
/// card, magenta accent, header with search + Sort by, left nav, footer action)
/// mirrors `MyClutterManagerView`; the panes reuse the existing uninstaller,
/// updater, extensions, and leftover collaborators.
struct ApplicationsManagerView: View {

    private var viewModel: ApplicationsViewModel
    private var uninstallerViewModel: AppUninstallerViewModel
    private var updaterViewModel: AppUpdaterViewModel
    private var extensionsManagerViewModel: ExtensionsManagerViewModel
    private let result: ApplicationsScanResult
    private var iconCache: AppIconCache
    private let onBack: () -> Void

    enum Pane: Hashable {
        case uninstaller
        case updater
        case extensions
        case leftovers
    }

    /// Which sub-list the Leftovers pane shows in its right column.
    private enum LeftoverSection: Hashable {
        case installers
        case leftoverFiles
    }

    /// The reference Manager uses a magenta accent on a white surface, the same
    /// one the My Clutter / Cleanup Managers adopt — independent of the
    /// Applications section's own hue.
    private static let accent = ManagerChrome.accent
    private static let selectionFill = Color(red: 0.45, green: 0.30, blue: 0.85).opacity(0.14)

    /// Middle-pane facet for the Updater pane.
    private enum UpdaterFacet: Hashable {
        case all
        case selected
        case store(isAppStore: Bool)
    }

    /// Middle-pane facet for the Extensions pane.
    private enum ExtensionsFacet: Hashable {
        case all
        case selected
        case type(ExtensionType)
    }

    @State private var pane: Pane
    @State private var search = ""
    @State private var sort: AppManagerSort = .name
    @State private var uninstallerFacet: AppManagerFacet = .all
    @State private var leftoverSection: LeftoverSection = .installers
    @State private var updaterFacet: UpdaterFacet = .all
    @State private var extensionsFacet: ExtensionsFacet = .all

    /// Checkbox selections for the Updater and Extensions panes, owned here
    /// because those collaborators expose per-item actions rather than a batch
    /// selection of their own.
    @State private var updateSelection: Set<UpdateInfo.ID> = []
    @State private var extensionSelection: Set<ExtensionItem.ID> = []

    /// App whose associated-files detail is open (chevron drill-in); `nil` shows
    /// the list.
    @State private var inspectingAppID: AppInfo.ID?
    /// Confirmation for the footer's batch uninstall (the checkbox selection).
    @State private var showUninstallConfirmation = false
    /// Confirmation for the single app open in the chevron detail.
    @State private var showSingleUninstallConfirmation = false

    // Off-main metrics for the uninstaller list: per-app size and last-opened
    // date. Rebuilt when the app list changes — the size walk is the expensive
    // pass discovery deliberately skips, so it runs detached, like
    // `MyClutterManagerView.rebuildCaches()`.
    @State private var sizes: [AppInfo.ID: Int64] = [:]
    @State private var lastOpened: [AppInfo.ID: Date] = [:]

    init(
        viewModel: ApplicationsViewModel,
        uninstallerViewModel: AppUninstallerViewModel,
        updaterViewModel: AppUpdaterViewModel,
        extensionsManagerViewModel: ExtensionsManagerViewModel,
        result: ApplicationsScanResult,
        iconCache: AppIconCache,
        initialPane: Pane = .uninstaller,
        onBack: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.uninstallerViewModel = uninstallerViewModel
        self.updaterViewModel = updaterViewModel
        self.extensionsManagerViewModel = extensionsManagerViewModel
        self.result = result
        self.iconCache = iconCache
        self._pane = State(initialValue: initialPane)
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                navigationPane.frame(width: 220)
                Divider().opacity(0.4)
                middlePane.frame(width: 320)
                Divider().opacity(0.4)
                rightPane.frame(maxWidth: .infinity)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .light)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(14)
        .ignoresSafeArea(.container, edges: .top)
        .tint(Self.accent)
        .environment(\.sectionAccent, Self.accent)
        .accessibilityIdentifier("applications.manager")
        .task {
            if uninstallerViewModel.phase == .idle { await uninstallerViewModel.loadApps() }
        }
        .task {
            if updaterViewModel.phase == .idle { await updaterViewModel.checkForUpdates() }
        }
        .task {
            if extensionsManagerViewModel.phase == .idle { await extensionsManagerViewModel.refresh() }
        }
        .task(id: uninstallerViewModel.apps.map(\.id)) { await rebuildMetrics() }
        .alert(uninstallConfirmationTitle, isPresented: $showUninstallConfirmation) {
            Button(String(localized: "Cancel", comment: "Cancel button on the uninstall confirmation."), role: .cancel) {}
            Button(String(localized: "Uninstall", comment: "Confirm batch uninstall."), role: .destructive) {
                Task { await uninstallerViewModel.uninstallSelected() }
            }
        } message: {
            Text(uninstallConfirmationMessage)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(String(localized: "Back", comment: "Back button on the Applications Manager."))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("applications.backToDashboard")

            Spacer()
            Text(String(localized: "Applications Manager", comment: "Applications Manager screen title."))
                .font(.headline)
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Search", comment: "Manager search placeholder."), text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 130)
                    .accessibilityIdentifier("applications.manager.search")
            }

            Menu {
                ForEach(AppManagerSort.allCases) { option in
                    Button(option.label) { sort = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "Sort by:", comment: "Manager sort label.")).foregroundStyle(.secondary)
                    Text(sort.label).foregroundStyle(.tint)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("applications.manager.sort")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Left nav

    private var navigationPane: some View {
        VStack(spacing: 4) {
            navRow(.uninstaller, String(localized: "Uninstaller", comment: "Applications Manager nav item."), "applications.manager.nav.uninstaller")
            navRow(.updater, String(localized: "Updater", comment: "Applications Manager nav item."), "applications.manager.nav.updater")
            navRow(.extensions, String(localized: "Extensions", comment: "Applications Manager nav item."), "applications.manager.nav.extensions")
            navRow(.leftovers, String(localized: "Leftovers", comment: "Applications Manager nav item."), "applications.manager.nav.leftovers")
            Spacer()
        }
        .padding(8)
    }

    private func navRow(_ target: Pane, _ title: String, _ identifier: String) -> some View {
        selectableRow(selected: pane == target) {
            pane = target
            inspectingAppID = nil
        } content: {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Middle pane

    @ViewBuilder
    private var middlePane: some View {
        switch pane {
        case .uninstaller:
            VStack(alignment: .leading, spacing: 0) {
                paneHeader(
                    title: String(localized: "Uninstaller", comment: "Uninstaller pane title."),
                    description: String(localized: "Correctly remove entire applications with all of the related files.", comment: "Uninstaller pane description.")
                )
                ScrollView { uninstallerFacets.padding(8) }
            }
        case .leftovers:
            VStack(alignment: .leading, spacing: 0) {
                paneHeader(
                    title: String(localized: "Leftovers", comment: "Leftovers pane title."),
                    description: String(localized: "If you manually remove an application file, all of its related items remain on your system. VaderCleaner locates and removes these leftovers even if the main app is already gone.", comment: "Leftovers pane description.")
                )
                ScrollView { leftoverSections.padding(8) }
            }
        case .updater:
            VStack(alignment: .leading, spacing: 0) {
                paneHeader(
                    title: String(localized: "Updater", comment: "Updater pane title."),
                    description: String(localized: "Keep your apps current with the latest fixes and features.", comment: "Updater pane description.")
                )
                ScrollView { updaterFacets.padding(8) }
            }
        case .extensions:
            VStack(alignment: .leading, spacing: 0) {
                paneHeader(
                    title: String(localized: "Extensions", comment: "Extensions pane title."),
                    description: String(localized: "Manage the add-ons and plug-ins installed into your browsers and apps.", comment: "Extensions pane description.")
                )
                ScrollView { extensionsFacets.padding(8) }
            }
        }
    }

    private var uninstallerFacets: some View {
        let apps = uninstallerViewModel.apps
        let stores = ApplicationsManagerModel.storeCounts(apps: apps)
        let vendors = ApplicationsManagerModel.vendorCounts(apps: apps)
        return VStack(spacing: 4) {
            facetRow(.all, String(localized: "All Applications", comment: "Uninstaller facet."), apps.count)
            facetRow(.unused, String(localized: "Unused", comment: "Uninstaller facet."), unusedIDs.count)
            facetRow(.suspicious, String(localized: "Suspicious", comment: "Uninstaller facet."), 0)
            facetRow(.selected, String(localized: "Selected", comment: "Uninstaller facet."), uninstallerViewModel.uninstallSelection.count)

            facetSectionHeader(String(localized: "Stores", comment: "Uninstaller facet group header."))
            facetRow(.store(isAppStore: true), String(localized: "App Store", comment: "Uninstaller store facet."), stores.appStore)
            facetRow(.store(isAppStore: false), String(localized: "Other", comment: "Uninstaller store facet."), stores.other)

            if !vendors.isEmpty {
                facetSectionHeader(String(localized: "Vendors", comment: "Uninstaller facet group header."))
                ForEach(vendors, id: \.vendor) { entry in
                    facetRow(.vendor(entry.vendor), entry.vendor.title, entry.count)
                }
            }
        }
    }

    private func facetRow(_ facet: AppManagerFacet, _ label: String, _ count: Int) -> some View {
        selectableRow(selected: uninstallerFacet == facet) {
            uninstallerFacet = facet
            inspectingAppID = nil
        } content: {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Text("\(count)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var leftoverSections: some View {
        VStack(spacing: 4) {
            leftoverRow(.installers,
                        Image("installerDmg"),
                        String(localized: "Installers", comment: "Leftovers section."),
                        result.installationFilesTotalBytes)
            leftoverRow(.leftoverFiles,
                        Image(systemName: "puzzlepiece.extension.fill"),
                        String(localized: "Leftover Files", comment: "Leftovers section."),
                        result.leftoversTotalBytes)
        }
    }

    private func leftoverRow(_ section: LeftoverSection, _ icon: Image, _ label: String, _ bytes: Int64) -> some View {
        selectableRow(selected: leftoverSection == section) {
            leftoverSection = section
        } content: {
            HStack(spacing: 12) {
                icon.resizable().aspectRatio(contentMode: .fit).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.body.weight(.medium))
                    Text(byteText(bytes)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func facetSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    // MARK: Updater middle pane

    private var updaterFacets: some View {
        let updates = updaterViewModel.availableUpdates
        let appStore = updates.filter { $0.source == .appStore }.count
        return VStack(spacing: 4) {
            updaterFacetRow(.all, String(localized: "All Updates", comment: "Updater facet."), updates.count)
            updaterFacetRow(.selected, String(localized: "Selected", comment: "Updater facet."), updateSelection.count)

            facetSectionHeader(String(localized: "Stores", comment: "Updater facet group header."))
            updaterFacetRow(.store(isAppStore: true), String(localized: "App Store", comment: "Updater store facet."), appStore)
            updaterFacetRow(.store(isAppStore: false), String(localized: "Other", comment: "Updater store facet."), updates.count - appStore)
        }
    }

    private func updaterFacetRow(_ facet: UpdaterFacet, _ label: String, _ count: Int) -> some View {
        selectableRow(selected: updaterFacet == facet) {
            updaterFacet = facet
        } content: {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Text("\(count)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Extensions middle pane

    private var extensionsFacets: some View {
        let grouped = extensionsManagerViewModel.groupedByType
        return VStack(spacing: 4) {
            extensionsFacetRow(.all, String(localized: "All Extensions", comment: "Extensions facet."), extensionsManagerViewModel.items.count)
            extensionsFacetRow(.selected, String(localized: "Selected", comment: "Extensions facet."), extensionSelection.count)

            if !grouped.isEmpty {
                facetSectionHeader(String(localized: "Categories", comment: "Extensions facet group header."))
                ForEach(grouped, id: \.0) { type, entries in
                    extensionsFacetRow(.type(type), localizedExtensionType(type), entries.count)
                }
            }
        }
    }

    private func extensionsFacetRow(_ facet: ExtensionsFacet, _ label: String, _ count: Int) -> some View {
        selectableRow(selected: extensionsFacet == facet) {
            extensionsFacet = facet
        } content: {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Text("\(count)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func localizedExtensionType(_ type: ExtensionType) -> String {
        switch type {
        case .safariExtension:  return String(localized: "Safari Extensions", comment: "Extension category.")
        case .chromeExtension:  return String(localized: "Chrome Extensions", comment: "Extension category.")
        case .firefoxExtension: return String(localized: "Firefox Extensions", comment: "Extension category.")
        case .mailPlugin:       return String(localized: "Mail Plugins", comment: "Extension category.")
        case .internetPlugin:   return String(localized: "Browser Plug-ins", comment: "Extension category.")
        }
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        switch pane {
        case .uninstaller:
            if let id = inspectingAppID {
                appDetail(id)
            } else if uninstallerViewModel.apps.isEmpty, uninstallerViewModel.phase == .loading {
                loadingPane
            } else {
                uninstallerList
            }
        case .updater:
            updaterPane
        case .extensions:
            extensionsPane
        case .leftovers:
            leftoverList
        }
    }

    private var displayedApps: [AppInfo] {
        let filtered = ApplicationsManagerModel.filter(
            uninstallerViewModel.apps,
            facet: uninstallerFacet,
            search: search,
            unusedIDs: unusedIDs,
            selectedIDs: uninstallerViewModel.uninstallSelection
        )
        return ApplicationsManagerModel.sort(filtered, by: sort, sizes: sizes, dates: lastOpened)
    }

    private var uninstallerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(displayedApps) { app in
                    appRow(app)
                    Divider().opacity(0.3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("applications.manager.uninstaller.list")
    }

    private func appRow(_ app: AppInfo) -> some View {
        HStack(spacing: 12) {
            checkbox(selected: uninstallerViewModel.isInUninstallSelection(app.id)) {
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
            // Decorative AI sparkle, matching the reference rows.
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(Color.pink)
            Text(dateText(lastOpened[app.id]))
                .font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
            Text(sizeText(sizes[app.id]))
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
        .padding(.vertical, 10)
        .accessibilityIdentifier("applications.manager.uninstaller.row.\(app.bundleID)")
    }

    private func appDetail(_ id: AppInfo.ID) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    inspectingAppID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
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

    // MARK: Updater right pane

    private var displayedUpdates: [UpdateInfo] {
        updaterViewModel.availableUpdates.filter { info in
            let matchesFacet: Bool
            switch updaterFacet {
            case .all:                    matchesFacet = true
            case .selected:               matchesFacet = updateSelection.contains(info.id)
            case .store(let isAppStore):  matchesFacet = (info.source == .appStore) == isAppStore
            }
            guard matchesFacet else { return false }
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || info.appName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    @ViewBuilder
    private var updaterPane: some View {
        if updaterViewModel.availableUpdates.isEmpty {
            emptyState(
                icon: "arrow.down.circle",
                title: String(localized: "Updater", comment: "Updater empty-state title."),
                detail: String(localized: "There are no items to clean or fix in this area.\nEverything is in order.", comment: "Updater empty-state detail.")
            )
            .accessibilityIdentifier("applications.manager.updater.empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedUpdates) { info in
                        updateRow(info)
                        Divider().opacity(0.3)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .accessibilityIdentifier("applications.manager.updater.list")
        }
    }

    private func updateRow(_ info: UpdateInfo) -> some View {
        HStack(spacing: 12) {
            checkbox(selected: updateSelection.contains(info.id)) {
                toggle(&updateSelection, info.id)
            }
            Image(nsImage: iconCache.icon(for: info.bundleURL))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.appName).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(versionTransition(info)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(info.source == .appStore
                 ? String(localized: "App Store", comment: "Update source label.")
                 : String(localized: "Web", comment: "Update source label."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier("applications.manager.updater.row.\(info.bundleID)")
    }

    private func versionTransition(_ info: UpdateInfo) -> String {
        let format = String(localized: "%1$@ → %2$@", comment: "Update row version change; installed → latest.")
        return String.localizedStringWithFormat(format, info.installedVersion, info.latestVersion)
    }

    // MARK: Extensions right pane

    private var displayedExtensions: [ExtensionItem] {
        let items = extensionsManagerViewModel.items.filter { item in
            let matchesFacet: Bool
            switch extensionsFacet {
            case .all:              matchesFacet = true
            case .selected:         matchesFacet = extensionSelection.contains(item.id)
            case .type(let type):   matchesFacet = item.type == type
            }
            guard matchesFacet else { return false }
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || item.name.localizedCaseInsensitiveContains(trimmed)
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var extensionsPane: some View {
        if extensionsManagerViewModel.items.isEmpty {
            emptyState(
                icon: "puzzlepiece.extension",
                title: String(localized: "Extensions", comment: "Extensions empty-state title."),
                detail: String(localized: "No browser extensions or plug-ins were found.", comment: "Extensions empty-state detail.")
            )
            .accessibilityIdentifier("applications.manager.extensions.empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedExtensions) { item in
                        extensionRow(item)
                        Divider().opacity(0.3)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .accessibilityIdentifier("applications.manager.extensions.list")
        }
    }

    private func extensionRow(_ item: ExtensionItem) -> some View {
        HStack(spacing: 12) {
            checkbox(selected: extensionSelection.contains(item.id)) {
                toggle(&extensionSelection, item.id)
            }
            Image(systemName: extensionSymbol(item.type))
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(localizedExtensionType(item.type)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(byteText(item.size)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier("applications.manager.extensions.row.\(item.id.path)")
    }

    private func extensionSymbol(_ type: ExtensionType) -> String {
        switch type {
        case .safariExtension:  return "safari"
        case .chromeExtension:  return "globe"
        case .firefoxExtension: return "globe"
        case .mailPlugin:       return "envelope"
        case .internetPlugin:   return "puzzlepiece.extension"
        }
    }

    /// Toggles `id` in a selection set in place.
    private func toggle<ID: Hashable>(_ set: inout Set<ID>, _ id: ID) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    @ViewBuilder
    private var leftoverList: some View {
        switch leftoverSection {
        case .installers:
            leftoverFileList(
                title: String(localized: "Unused DMG Files", comment: "Installers list title."),
                description: String(localized: "Save space by removing unneeded DMGs or other installation files of applications.", comment: "Installers list description."),
                rows: result.installationFiles.map { file in
                    LeftoverDisplayRow(id: file.url.path, name: file.name, bytes: file.sizeBytes,
                                       selected: viewModel.isInstallationFileSelected(file),
                                       toggle: { viewModel.toggleInstallationFile(file) })
                },
                onSelectNone: viewModel.clearInstallationFileSelection,
                onSelectAll: viewModel.selectAllInstallationFiles,
                usesDiskIcon: true
            )
        case .leftoverFiles:
            leftoverFileList(
                title: String(localized: "Leftover Files", comment: "Leftover files list title."),
                description: String(localized: "Support files left behind by apps you've removed.", comment: "Leftover files list description."),
                rows: result.leftovers.map { group in
                    LeftoverDisplayRow(id: group.bundleID, name: group.displayName, bytes: group.totalBytes,
                                       selected: viewModel.isLeftoverSelected(group),
                                       toggle: { viewModel.toggleLeftover(group) })
                },
                onSelectNone: viewModel.clearLeftoverSelection,
                onSelectAll: viewModel.selectAllLeftovers,
                usesDiskIcon: false
            )
        }
    }

    /// One row's display data for the Leftovers lists, with its own toggle so a
    /// single renderer serves both installers and leftover groups.
    private struct LeftoverDisplayRow: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let selected: Bool
        let toggle: () -> Void
    }

    private func leftoverFileList(
        title: String,
        description: String,
        rows: [LeftoverDisplayRow],
        onSelectNone: @escaping () -> Void,
        onSelectAll: @escaping () -> Void,
        usesDiskIcon: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(description).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(String(localized: "Select:", comment: "Manager bulk-select label.")).foregroundStyle(.secondary)
                    Menu {
                        Button(String(localized: "All", comment: "Select all.")) { onSelectAll() }
                        Button(String(localized: "None", comment: "Deselect all.")) { onSelectNone() }
                    } label: {
                        Text(rows.contains(where: \.selected)
                             ? String(localized: "Some", comment: "Some selected.")
                             : String(localized: "None", comment: "None selected."))
                        .foregroundStyle(.tint)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            if rows.isEmpty {
                emptyState(icon: "checkmark.seal.fill",
                           title: String(localized: "Nothing to remove", comment: "Empty leftovers list."),
                           detail: String(localized: "There are no items in this area.", comment: "Empty leftovers detail."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                checkbox(selected: row.selected, action: row.toggle)
                                if usesDiskIcon {
                                    Image("installerDmg").resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "folder.badge.minus").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 28)
                                }
                                Text(row.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(byteText(row.bytes)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture { row.toggle() }
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch pane {
        case .uninstaller:
            actionFooter(
                summary: uninstallSummary,
                actionLabel: String(localized: "Uninstall", comment: "Footer action removing the selected apps."),
                enabled: uninstallerViewModel.canUninstallSelection,
                identifier: "applications.manager.uninstall"
            ) { showUninstallConfirmation = true }
        case .updater:
            actionFooter(
                summary: updaterSummary,
                actionLabel: String(localized: "Update", comment: "Footer action applying updates."),
                enabled: !updateSelection.isEmpty,
                identifier: "applications.manager.update"
            ) { Task { await updateSelected() } }
        case .leftovers:
            actionFooter(
                summary: leftoverSummary,
                actionLabel: String(localized: "Remove", comment: "Footer action removing the selected leftover items."),
                enabled: leftoverCanRemove,
                identifier: "applications.manager.remove"
            ) { Task { await removeSelectedLeftovers() } }
        case .extensions:
            actionFooter(
                summary: extensionsSummary,
                actionLabel: String(localized: "Remove", comment: "Footer action removing the selected extensions."),
                enabled: !extensionSelection.isEmpty,
                identifier: "applications.manager.extensions.remove"
            ) { Task { await removeSelectedExtensions() } }
        }
    }

    /// Opens the update URL for every selected update.
    private func updateSelected() async {
        for info in updaterViewModel.availableUpdates where updateSelection.contains(info.id) {
            await updaterViewModel.update(info)
        }
    }

    /// Removes every selected extension, dropping each from the selection.
    private func removeSelectedExtensions() async {
        let targets = extensionsManagerViewModel.items.filter { extensionSelection.contains($0.id) }
        for item in targets {
            await extensionsManagerViewModel.remove(item)
        }
        extensionSelection = extensionSelection.intersection(Set(extensionsManagerViewModel.items.map(\.id)))
    }

    private var updaterSummary: String {
        guard !updateSelection.isEmpty else {
            return String(localized: "No Applications Selected", comment: "Updater footer, nothing selected.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld Applications Selected", comment: "Updater footer selected count."),
            Int64(updateSelection.count)
        )
    }

    private var extensionsSummary: String {
        let selected = extensionsManagerViewModel.items.filter { extensionSelection.contains($0.id) }
        guard !selected.isEmpty else {
            return String(localized: "No Items Selected", comment: "Extensions footer, nothing selected.")
        }
        let bytes = selected.reduce(Int64(0)) { $0 + $1.size }
        let count = String.localizedStringWithFormat(
            String(localized: "%lld Items Selected", comment: "Extensions footer selected count."),
            Int64(selected.count)
        )
        return "\(count)  ·  \(byteText(bytes))"
    }

    private func actionFooter(
        summary: String,
        actionLabel: String,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(summary).font(.callout.weight(.medium))
                .accessibilityIdentifier("applications.manager.summary")
            Spacer()
            Button(actionLabel, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: - Shared pieces

    private func paneHeader(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
    }

    private func selectableRow<Content: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Self.selectionFill : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func checkbox(selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 18))
                .foregroundStyle(selected ? Self.accent : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var loadingPane: some View {
        VStack { Spacer(); ProgressView().controlSize(.large); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("applications.manager.loading")
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.tint.opacity(0.7))
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived values

    /// `AppInfo.ID` (bundle-URL path) of every app the scan flagged as unused.
    private var unusedIDs: Set<AppInfo.ID> {
        Set(result.unusedApps.map { $0.app.id })
    }

    private var uninstallSummary: String {
        let selection = uninstallerViewModel.uninstallSelection
        guard !selection.isEmpty else {
            return String(localized: "No Applications Selected", comment: "Uninstaller footer, nothing selected.")
        }
        let bytes = selection.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        let count = String.localizedStringWithFormat(
            String(localized: "%lld Applications Selected", comment: "Uninstaller footer selected count."),
            Int64(selection.count)
        )
        return "\(count)  ·  \(byteText(bytes))"
    }

    private var leftoverSummary: String {
        let (count, bytes) = leftoverSelectionTotals
        guard count > 0 else {
            return String(localized: "No Items Selected", comment: "Leftovers footer, nothing selected.")
        }
        let countText = String.localizedStringWithFormat(
            String(localized: "%lld Items Selected", comment: "Leftovers footer selected count."),
            Int64(count)
        )
        return "\(countText)  ·  \(byteText(bytes))"
    }

    private var leftoverSelectionTotals: (count: Int, bytes: Int64) {
        switch leftoverSection {
        case .installers:
            let selected = result.installationFiles.filter(viewModel.isInstallationFileSelected)
            return (selected.count, selected.reduce(Int64(0)) { $0 + $1.sizeBytes })
        case .leftoverFiles:
            let selected = result.leftovers.filter(viewModel.isLeftoverSelected)
            return (selected.count, selected.reduce(Int64(0)) { $0 + $1.totalBytes })
        }
    }

    private var leftoverCanRemove: Bool {
        switch leftoverSection {
        case .installers:    return viewModel.canRemoveInstallationFiles
        case .leftoverFiles: return viewModel.canRemoveLeftovers
        }
    }

    private func removeSelectedLeftovers() async {
        switch leftoverSection {
        case .installers:    await viewModel.deleteSelectedInstallationFiles()
        case .leftoverFiles: await viewModel.deleteSelectedLeftovers()
        }
    }

    private var uninstallConfirmationTitle: String {
        String(localized: "Move the selected apps and their data to Trash?", comment: "Batch uninstall confirmation title.")
    }

    private var uninstallConfirmationMessage: String {
        String(localized: "The selected applications and their associated files will be moved to the Trash. You can restore them until you empty it.", comment: "Batch uninstall confirmation message.")
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

    // MARK: - Metrics

    private func rebuildMetrics() async {
        let apps = uninstallerViewModel.apps
        guard !apps.isEmpty else { sizes = [:]; lastOpened = [:]; return }
        let computed = await Task.detached(priority: .utility) { () -> (sizes: [AppInfo.ID: Int64], dates: [AppInfo.ID: Date]) in
            var sizes: [AppInfo.ID: Int64] = [:]
            var dates: [AppInfo.ID: Date] = [:]
            let fileManager = FileManager.default
            for app in apps {
                sizes[app.id] = DefaultAppDiscovery.bundleSize(at: app.bundleURL, fileManager: fileManager)
                dates[app.id] = DefaultUnusedAppScanner.spotlightLastUsedDate(app)
            }
            return (sizes, dates)
        }.value
        sizes = computed.sizes
        lastOpened = computed.dates
    }

    // MARK: - Formatting

    private func byteText(_ bytes: Int64) -> String {
        smartScanByteFormatter.string(fromByteCount: bytes)
    }

    private func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return smartScanByteFormatter.string(fromByteCount: bytes)
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
