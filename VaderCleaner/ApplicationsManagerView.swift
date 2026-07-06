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
        case unsupported
    }

    /// A place in the manager a dashboard card can deep-link straight to, so
    /// every "Review" button lands on the pane (and facet / leftover section)
    /// where its finding actually lives instead of pushing a separate screen.
    enum Destination: Hashable {
        case uninstaller
        case unused
        case updater
        case extensions
        case leftovers
        case installationFiles
        case unsupported
    }

    /// The reference Manager uses a magenta accent on a white surface, the same
    /// one the My Clutter / Cleanup Managers adopt — independent of the
    /// Applications section's own hue.
    private static let accent = ApplicationsManagerChrome.accent

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

    // The filtered, sorted uninstaller list, memoized so a checkbox toggle
    // re-renders the rows without re-running the O(n log n) filter + sort over
    // every app. Recomputed only when an input that actually changes the list
    // changes — facet, search, sort, the app roster, the measured metrics, and
    // (only under the Selected facet) the selection.
    @State private var displayedApps: [AppInfo] = []
    // The Updater and Extensions lists, memoized for the same reason: their
    // filter (and the Extensions sort) ran on every render, so toggling a row's
    // checkbox re-filtered the whole list. Recomputed only on their real inputs.
    @State private var displayedUpdates: [UpdateInfo] = []
    @State private var displayedExtensions: [ExtensionItem] = []

    init(
        viewModel: ApplicationsViewModel,
        uninstallerViewModel: AppUninstallerViewModel,
        updaterViewModel: AppUpdaterViewModel,
        extensionsManagerViewModel: ExtensionsManagerViewModel,
        result: ApplicationsScanResult,
        iconCache: AppIconCache,
        destination: Destination = .uninstaller,
        onBack: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.uninstallerViewModel = uninstallerViewModel
        self.updaterViewModel = updaterViewModel
        self.extensionsManagerViewModel = extensionsManagerViewModel
        self.result = result
        self.iconCache = iconCache
        self.onBack = onBack

        let (pane, facet, leftoverSection) = Self.resolve(destination)
        self._pane = State(initialValue: pane)
        self._uninstallerFacet = State(initialValue: facet)
        self._leftoverSection = State(initialValue: leftoverSection)
    }

    /// Maps a deep-link destination to the pane, uninstaller facet, and leftover
    /// section it opens on. A card's Review button carries only the destination;
    /// this resolves it to the concrete selection the panes read.
    private static func resolve(_ destination: Destination) -> (Pane, AppManagerFacet, LeftoverSection) {
        switch destination {
        case .uninstaller:       return (.uninstaller, .all, .installers)
        case .unused:            return (.uninstaller, .unused, .installers)
        case .updater:           return (.updater, .all, .installers)
        case .extensions:        return (.extensions, .all, .installers)
        case .leftovers:         return (.leftovers, .all, .leftoverFiles)
        case .installationFiles: return (.leftovers, .all, .installers)
        case .unsupported:       return (.unsupported, .all, .installers)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                navigationPane.frame(width: 220)
                Divider().opacity(0.4)
                paneContent
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
        .task(id: uninstallerViewModel.apps.map(\.id)) { await uninstallerViewModel.loadListMetrics() }
        // Warm the shared icon cache for every roster this manager renders.
        // The cache never loads on a miss — `icon(for:)` returns the generic
        // placeholder until a preload lands — so without these the rows only
        // show real icons for apps some other card happened to preload.
        // `preloadIcons` skips URLs already cached, so re-runs cost nothing.
        .task(id: uninstallerViewModel.apps.map(\.id)) {
            await iconCache.preloadIcons(for: uninstallerViewModel.apps.map(\.bundleURL))
        }
        .task(id: updaterViewModel.availableUpdates.map(\.bundleID)) {
            await iconCache.preloadIcons(for: updaterViewModel.availableUpdates.map(\.bundleURL))
        }
        .alert(uninstallConfirmationTitle, isPresented: $showUninstallConfirmation) {
            Button(String(localized: "Cancel", comment: "Cancel button on the uninstall confirmation."), role: .cancel) {}
            Button(String(localized: "Uninstall", comment: "Confirm batch uninstall."), role: .destructive) {
                Task { await uninstallerViewModel.uninstallSelected() }
            }
        } message: {
            Text(uninstallConfirmationMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").foregroundStyle(.tint)
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
                Image(systemName: "magnifyingglass").foregroundStyle(.tint)
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
            navRow(.unsupported, String(localized: "Unsupported", comment: "Applications Manager nav item."), "applications.manager.nav.unsupported")
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

    // MARK: - Pane content

    /// The center of the manager: the active pane's facet column and right pane.
    /// Each pane is its own subview, so a checkbox toggle re-renders only that
    /// pane rather than the whole manager.
    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .uninstaller:
            UninstallerPaneView(
                uninstallerViewModel: uninstallerViewModel,
                result: result,
                iconCache: iconCache,
                search: search,
                sort: sort,
                facet: $uninstallerFacet,
                inspectingAppID: $inspectingAppID,
                displayedApps: $displayedApps
            )
        case .updater:
            UpdaterPaneView(
                updaterViewModel: updaterViewModel,
                iconCache: iconCache,
                search: search,
                facet: $updaterFacet,
                selection: $updateSelection,
                displayed: $displayedUpdates
            )
        case .extensions:
            ExtensionsPaneView(
                extensionsManagerViewModel: extensionsManagerViewModel,
                search: search,
                facet: $extensionsFacet,
                selection: $extensionSelection,
                displayed: $displayedExtensions
            )
        case .leftovers:
            LeftoversPaneView(
                viewModel: viewModel,
                result: result,
                section: $leftoverSection
            )
        case .unsupported:
            UnsupportedPaneView(
                viewModel: viewModel,
                result: result,
                iconCache: iconCache,
                search: search
            )
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
        case .unsupported:
            actionFooter(
                summary: unsupportedSummary,
                actionLabel: String(localized: "Move to Trash", comment: "Footer action removing the selected unsupported apps."),
                enabled: viewModel.canRemoveUnsupportedApps,
                identifier: "applications.manager.unsupported.remove"
            ) { Task { await viewModel.deleteSelectedUnsupportedApps() } }
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

    private var unsupportedSummary: String {
        let selected = result.unsupportedApps.filter(viewModel.isUnsupportedAppSelected)
        guard !selected.isEmpty else {
            return String(localized: "No Applications Selected", comment: "Unsupported footer, nothing selected.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld Applications Selected", comment: "Unsupported footer selected count."),
            Int64(selected.count)
        )
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

    private func selectableRow<Content: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ApplicationsManagerSelectableRow(selected: selected, action: action, content: content)
    }

    // MARK: - Derived values

    private var uninstallSummary: String {
        let selection = uninstallerViewModel.uninstallSelection
        guard !selection.isEmpty else {
            return String(localized: "No Applications Selected", comment: "Uninstaller footer, nothing selected.")
        }
        let bytes = selection.reduce(Int64(0)) { $0 + (uninstallerViewModel.listSizes[$1] ?? 0) }
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

    // MARK: - Formatting

    private func byteText(_ bytes: Int64) -> String {
        ApplicationsManagerChrome.byteText(bytes)
    }
}

// MARK: - Uninstaller pane

/// The Uninstaller pane — the facet column plus the app list (or an app's
/// associated-files detail). Extracted from `ApplicationsManagerView` so a
/// checkbox toggle re-renders only this pane, not the whole manager. `facet`,
/// the drill-in, and the memoized list are owned by the parent (via bindings) so
/// they persist across pane switches; the batch metrics preload stays on the
/// parent, this pane just reads the resulting caches.
private struct UninstallerPaneView: View {
    let uninstallerViewModel: AppUninstallerViewModel
    let result: ApplicationsScanResult
    let iconCache: AppIconCache
    let search: String
    let sort: AppManagerSort
    @Binding var facet: AppManagerFacet
    @Binding var inspectingAppID: AppInfo.ID?
    @Binding var displayedApps: [AppInfo]

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

            if !vendors.isEmpty {
                ApplicationsManagerFacetSectionHeader(title: String(localized: "Vendors", comment: "Uninstaller facet group header."))
                ForEach(vendors, id: \.vendor) { entry in
                    facetRow(.vendor(entry.vendor), entry.vendor.title, entry.count)
                }
            }
        }
    }

    private func facetRow(_ target: AppManagerFacet, _ label: String, _ count: Int) -> some View {
        ApplicationsManagerSelectableRow(selected: facet == target) {
            facet = target
            inspectingAppID = nil
        } content: {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Text("\(count)").font(.callout).foregroundStyle(.secondary)
            }
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
        }
    }

    // MARK: Right (list / detail)

    @ViewBuilder
    private var rightColumn: some View {
        if let id = inspectingAppID {
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
            sizes: uninstallerViewModel.listSizes,
            dates: uninstallerViewModel.listLastOpened
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
            // Decorative AI sparkle, matching the reference rows.
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(Color.pink)
            Text(dateText(uninstallerViewModel.listLastOpened[app.id]))
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

// MARK: - Leftovers pane

/// Which sub-list the Leftovers pane shows in its right column.
private enum LeftoverSection: Hashable {
    case installers
    case leftoverFiles
}

/// The Leftovers pane — the Installers / Leftover Files section column plus the
/// matching file list. Extracted from `ApplicationsManagerView`; the section
/// selection stays on the parent (the footer's Remove action reads it too) and
/// is passed in as a binding.
private struct LeftoversPaneView: View {
    let viewModel: ApplicationsViewModel
    let result: ApplicationsScanResult
    @Binding var section: LeftoverSection

    var body: some View {
        HStack(spacing: 0) {
            middleColumn.frame(width: 320)
            Divider().opacity(0.4)
            rightColumn.frame(maxWidth: .infinity)
        }
    }

    // MARK: Middle (sections)

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Leftovers", comment: "Leftovers pane title."),
                description: String(localized: "If you manually remove an application file, all of its related items remain on your system. VaderCleaner locates and removes these leftovers even if the main app is already gone.", comment: "Leftovers pane description.")
            )
            ScrollView { sections.padding(8) }
        }
    }

    private var sections: some View {
        VStack(spacing: 4) {
            sectionRow(.installers,
                       Image("installerDmg"),
                       String(localized: "Installers", comment: "Leftovers section."),
                       result.installationFilesTotalBytes)
            sectionRow(.leftoverFiles,
                       Image(systemName: "puzzlepiece.extension.fill"),
                       String(localized: "Leftover Files", comment: "Leftovers section."),
                       result.leftoversTotalBytes)
        }
    }

    private func sectionRow(_ target: LeftoverSection, _ icon: Image, _ label: String, _ bytes: Int64) -> some View {
        ApplicationsManagerSelectableRow(selected: section == target) {
            section = target
        } content: {
            HStack(spacing: 12) {
                icon.resizable().aspectRatio(contentMode: .fit).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.body.weight(.medium))
                    Text(ApplicationsManagerChrome.byteText(bytes)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: Right (file list)

    @ViewBuilder
    private var rightColumn: some View {
        switch section {
        case .installers:
            fileList(
                title: String(localized: "Unused DMG Files", comment: "Installers list title."),
                description: String(localized: "Save space by removing unneeded DMGs or other installation files of applications.", comment: "Installers list description."),
                rows: result.installationFiles.map { file in
                    DisplayRow(id: file.url.path, name: file.name, bytes: file.sizeBytes,
                               selected: viewModel.isInstallationFileSelected(file),
                               toggle: { viewModel.toggleInstallationFile(file) })
                },
                onSelectNone: viewModel.clearInstallationFileSelection,
                onSelectAll: viewModel.selectAllInstallationFiles,
                usesDiskIcon: true
            )
        case .leftoverFiles:
            fileList(
                title: String(localized: "Leftover Files", comment: "Leftover files list title."),
                description: String(localized: "Support files left behind by apps you've removed.", comment: "Leftover files list description."),
                rows: result.leftovers.map { group in
                    DisplayRow(id: group.bundleID, name: group.displayName, bytes: group.totalBytes,
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
    private struct DisplayRow: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let selected: Bool
        let toggle: () -> Void
    }

    private func fileList(
        title: String,
        description: String,
        rows: [DisplayRow],
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
                ApplicationsManagerEmptyState(
                    icon: "checkmark.seal.fill",
                    title: String(localized: "Nothing to remove", comment: "Empty leftovers list."),
                    detail: String(localized: "There are no items in this area.", comment: "Empty leftovers detail.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                ApplicationsManagerCheckbox(selected: row.selected, action: row.toggle)
                                if usesDiskIcon {
                                    Image("installerDmg").resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "folder.badge.minus").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 28)
                                }
                                Text(row.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(ApplicationsManagerChrome.byteText(row.bytes)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { row.toggle() }
                            .padding(12)
                            .managerRowCard()
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
        }
    }
}

// MARK: - Unsupported pane

/// The Unsupported pane — a single-section column plus the list of apps that
/// can't run on this macOS, each with a checkbox. Selection lives on
/// `ApplicationsViewModel` (the footer's Move to Trash action reads it), the
/// same model the Leftovers pane uses.
private struct UnsupportedPaneView: View {
    let viewModel: ApplicationsViewModel
    let result: ApplicationsScanResult
    let iconCache: AppIconCache
    let search: String

    var body: some View {
        HStack(spacing: 0) {
            middleColumn.frame(width: 320)
            Divider().opacity(0.4)
            rightColumn.frame(maxWidth: .infinity)
        }
        .task(id: result.unsupportedApps.map(\.id)) {
            await iconCache.preloadIcons(for: result.unsupportedApps.map(\.app.bundleURL))
        }
    }

    // MARK: Middle (single section)

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Unsupported", comment: "Unsupported pane title."),
                description: String(localized: "These apps won't run on this version of macOS — their code is built only for older architectures.", comment: "Unsupported pane description.")
            )
            ScrollView {
                VStack(spacing: 4) {
                    ApplicationsManagerSelectableRow(selected: true, action: {}) {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 28)
                            Text(String(localized: "All Unsupported", comment: "Unsupported section."))
                                .font(.body.weight(.medium))
                            Spacer()
                            Text("\(result.unsupportedApps.count)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: Right (list)

    private var displayedApps: [UnsupportedApp] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result.unsupportedApps }
        return result.unsupportedApps.filter {
            $0.app.name.localizedCaseInsensitiveContains(trimmed)
                || $0.app.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Unsupported Applications", comment: "Unsupported list title."))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "Move apps that can't run on this Mac to the Trash. Only the app bundle is removed here; full cleanup is available in the Uninstaller.", comment: "Unsupported list description."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(String(localized: "Select:", comment: "Manager bulk-select label.")).foregroundStyle(.secondary)
                    Menu {
                        Button(String(localized: "All", comment: "Select all.")) { viewModel.selectAllUnsupportedApps() }
                        Button(String(localized: "None", comment: "Deselect all.")) { viewModel.clearUnsupportedAppSelection() }
                    } label: {
                        Text(result.unsupportedApps.contains(where: viewModel.isUnsupportedAppSelected)
                             ? String(localized: "Some", comment: "Some selected.")
                             : String(localized: "None", comment: "None selected."))
                        .foregroundStyle(.tint)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        if result.unsupportedApps.isEmpty {
            ApplicationsManagerEmptyState(
                icon: "checkmark.seal.fill",
                title: String(localized: "Unsupported", comment: "Unsupported empty-state title."),
                detail: String(localized: "Every installed app can run on this version of macOS.", comment: "Unsupported empty-state detail.")
            )
            .accessibilityIdentifier("applications.manager.unsupported.empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(displayedApps) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .accessibilityIdentifier("applications.manager.unsupported.list")
        }
    }

    private func row(_ entry: UnsupportedApp) -> some View {
        HStack(spacing: 12) {
            ApplicationsManagerCheckbox(selected: viewModel.isUnsupportedAppSelected(entry)) {
                viewModel.toggleUnsupportedApp(entry)
            }
            Image(nsImage: iconCache.icon(for: entry.app.bundleURL))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.app.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(reasonText(entry)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggleUnsupportedApp(entry) }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("applications.manager.unsupported.row.\(entry.app.bundleID)")
    }

    private func reasonText(_ entry: UnsupportedApp) -> String {
        switch entry.reason {
        case .incompatibleArchitecture:
            return String(localized: "Won't run on this macOS — built for an older architecture", comment: "Reason label for an unsupported app with no runnable architecture.")
        }
    }
}

// MARK: - Updater pane

/// Middle-pane facet for the Updater pane.
private enum UpdaterFacet: Hashable {
    case all
    case selected
    case store(isAppStore: Bool)
}

/// The Updater pane — the facet column plus the available-updates list.
/// Extracted from `ApplicationsManagerView`; the facet, selection, and memoized
/// list are owned by the parent (the footer's Update action reads the selection)
/// and passed in as bindings.
private struct UpdaterPaneView: View {
    let updaterViewModel: AppUpdaterViewModel
    let iconCache: AppIconCache
    let search: String
    @Binding var facet: UpdaterFacet
    @Binding var selection: Set<UpdateInfo.ID>
    @Binding var displayed: [UpdateInfo]

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
        }
    }

    private func facetRow(_ target: UpdaterFacet, _ label: String, _ count: Int) -> some View {
        ApplicationsManagerSelectableRow(selected: facet == target) {
            facet = target
        } content: {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Text("\(count)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var rightPaneTitle: String {
        switch facet {
        case .all:              return String(localized: "All Updates", comment: "Updater right pane title.")
        case .selected:         return String(localized: "Selected", comment: "Updater right pane title.")
        case .store(true):      return String(localized: "App Store", comment: "Updater right pane title.")
        case .store(false):     return String(localized: "Other", comment: "Updater right pane title.")
        }
    }

    private var rightPaneDescription: String {
        switch facet {
        case .all:              return String(localized: "Apps with new versions available.", comment: "Updater right pane description.")
        case .selected:         return String(localized: "Updates you've chosen to install.", comment: "Updater right pane description.")
        case .store(true):      return String(localized: "Updates available through the Mac App Store.", comment: "Updater right pane description.")
        case .store(false):     return String(localized: "Updates available from developer websites.", comment: "Updater right pane description.")
        }
    }

    // MARK: Right (list)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(title: rightPaneTitle, description: rightPaneDescription)
            list
        }
    }

    private func recompute() {
        displayed = updaterViewModel.availableUpdates.filter { info in
            let matchesFacet: Bool
            switch facet {
            case .all:                    matchesFacet = true
            case .selected:               matchesFacet = selection.contains(info.id)
            case .store(let isAppStore):  matchesFacet = (info.source == .appStore) == isAppStore
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
            Text(info.source == .appStore
                 ? String(localized: "App Store", comment: "Update source label.")
                 : String(localized: "Web", comment: "Update source label."))
                .font(.caption).foregroundStyle(.secondary)
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

// MARK: - Extensions pane

/// Middle-pane facet for the Extensions pane.
private enum ExtensionsFacet: Hashable {
    case all
    case selected
    case type(ExtensionType)
}

/// The Extensions pane — the facet column plus the extensions/plug-ins list.
/// Extracted from `ApplicationsManagerView`; the facet, selection, and memoized
/// list are owned by the parent (the footer's Remove action reads the selection)
/// and passed in as bindings.
private struct ExtensionsPaneView: View {
    let extensionsManagerViewModel: ExtensionsManagerViewModel
    let search: String
    @Binding var facet: ExtensionsFacet
    @Binding var selection: Set<ExtensionItem.ID>
    @Binding var displayed: [ExtensionItem]

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
                title: String(localized: "Extensions", comment: "Extensions pane title."),
                description: String(localized: "Manage the add-ons and plug-ins installed into your browsers and apps.", comment: "Extensions pane description.")
            )
            ScrollView { facets.padding(8) }
        }
    }

    private var facets: some View {
        let grouped = extensionsManagerViewModel.groupedByType
        return VStack(spacing: 4) {
            facetRow(.all, String(localized: "All Extensions", comment: "Extensions facet."), extensionsManagerViewModel.items.count)
            facetRow(.selected, String(localized: "Selected", comment: "Extensions facet."), selection.count)

            if !grouped.isEmpty {
                ApplicationsManagerFacetSectionHeader(title: String(localized: "Categories", comment: "Extensions facet group header."))
                ForEach(grouped, id: \.0) { type, entries in
                    facetRow(.type(type), localizedExtensionType(type), entries.count)
                }
            }
        }
    }

    private func facetRow(_ target: ExtensionsFacet, _ label: String, _ count: Int) -> some View {
        ApplicationsManagerSelectableRow(selected: facet == target) {
            facet = target
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

    private var rightPaneTitle: String {
        switch facet {
        case .all:              return String(localized: "All Extensions", comment: "Extensions right pane title.")
        case .selected:         return String(localized: "Selected", comment: "Extensions right pane title.")
        case .type(let t):      return localizedExtensionType(t)
        }
    }

    private var rightPaneDescription: String {
        switch facet {
        case .all:              return String(localized: "Every extension and plug-in installed on this Mac.", comment: "Extensions right pane description.")
        case .selected:         return String(localized: "Extensions you've chosen to remove.", comment: "Extensions right pane description.")
        case .type(let t):
            switch t {
            case .safariExtension:  return String(localized: "Extensions installed in Safari.", comment: "Safari extensions right pane description.")
            case .chromeExtension:  return String(localized: "Extensions installed in Google Chrome.", comment: "Chrome extensions right pane description.")
            case .firefoxExtension: return String(localized: "Extensions installed in Firefox.", comment: "Firefox extensions right pane description.")
            case .mailPlugin:       return String(localized: "Plug-ins installed in the Mail app.", comment: "Mail plugins right pane description.")
            case .internetPlugin:   return String(localized: "Legacy plug-ins used by web browsers.", comment: "Browser plug-ins right pane description.")
            }
        }
    }

    // MARK: Right (list)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(title: rightPaneTitle, description: rightPaneDescription)
            list
        }
    }

    private func recompute() {
        let items = extensionsManagerViewModel.items.filter { item in
            let matchesFacet: Bool
            switch facet {
            case .all:              matchesFacet = true
            case .selected:         matchesFacet = selection.contains(item.id)
            case .type(let type):   matchesFacet = item.type == type
            }
            guard matchesFacet else { return false }
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || item.name.localizedCaseInsensitiveContains(trimmed)
        }
        displayed = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var list: some View {
        // The recompute hooks stay attached to the outer Group so they fire in
        // both branches — otherwise an initially empty `displayed` would pin the
        // empty state and never recompute into the list.
        Group {
            if displayed.isEmpty {
                ApplicationsManagerEmptyState(
                    icon: "puzzlepiece.extension",
                    title: String(localized: "Extensions", comment: "Extensions empty-state title."),
                    detail: String(localized: "No browser extensions or plug-ins were found.", comment: "Extensions empty-state detail.")
                )
                .accessibilityIdentifier("applications.manager.extensions.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(displayed) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
                .accessibilityIdentifier("applications.manager.extensions.list")
            }
        }
        .onAppear { recompute() }
        .onChange(of: facet) { _, _ in recompute() }
        .onChange(of: search) { _, _ in recompute() }
        .onChange(of: extensionsManagerViewModel.items.map(\.id)) { _, _ in recompute() }
        // The selection only changes the visible list under the Selected facet.
        .onChange(of: selection) { _, _ in
            if facet == .selected { recompute() }
        }
    }

    private func row(_ item: ExtensionItem) -> some View {
        HStack(spacing: 12) {
            ApplicationsManagerCheckbox(selected: selection.contains(item.id)) {
                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            }
            Image(systemName: symbol(item.type))
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(localizedExtensionType(item.type)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(ApplicationsManagerChrome.byteText(item.size)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("applications.manager.extensions.row.\(item.id.path)")
    }

    private func symbol(_ type: ExtensionType) -> String {
        switch type {
        case .safariExtension:  return "safari"
        case .chromeExtension:  return "globe"
        case .firefoxExtension: return "globe"
        case .mailPlugin:       return "envelope"
        case .internetPlugin:   return "puzzlepiece.extension"
        }
    }
}

// MARK: - Shared chrome

/// Constants and helpers shared by the Applications Manager and its pane
/// subviews. The accent is the standalone Manager magenta shared across the
/// manager screens.
enum ApplicationsManagerChrome {
    static let accent = ManagerChrome.accent

    static func byteText(_ bytes: Int64) -> String {
        smartScanByteFormatter.string(fromByteCount: bytes)
    }
}

/// A pane's title + description block, above its facet list or item list.
struct ApplicationsManagerPaneHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
    }
}

/// A nav / facet / section row with the manager's selection pill and a quieter
/// hover fill — the magenta `ManagerChrome.accent` active/hover states every
/// manager's left and middle panes share (active fill plus a border, hover a
/// lighter fill with no border).
struct ApplicationsManagerSelectableRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? ManagerChrome.accent.opacity(0.22) : (hovered ? ManagerChrome.accent.opacity(0.08) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? ManagerChrome.accent.opacity(0.40) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A row checkbox tinted with the manager accent when selected.
struct ApplicationsManagerCheckbox: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        ManagerRowCheckbox(isOn: selected, action: action)
    }
}

/// A quiet group header inside a facet column ("Stores", "Vendors", …).
struct ApplicationsManagerFacetSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

/// Centered icon + title + detail empty state for a pane with no items.
struct ApplicationsManagerEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.tint.opacity(0.7))
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right pane's loading spinner while the app list is still discovering.
struct ApplicationsManagerLoadingPane: View {
    var body: some View {
        VStack { Spacer(); ProgressView().controlSize(.large); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("applications.manager.loading")
    }
}
