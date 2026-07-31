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
    private var homebrewViewModel: HomebrewViewModel
    private let result: ApplicationsScanResult
    private var iconCache: AppIconCache
    /// The deep-link target the manager (re)opens on. A fresh instance resolves
    /// it in `init`; a retained one re-resolves it when `isPresented` flips.
    private let destination: Destination
    /// Whether the manager is the visible surface. The host keeps this manager
    /// alive between opens (hidden behind the dashboard) and flips this so each
    /// open re-aims the panes at `destination`.
    private let isPresented: Bool
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

    /// Batch selections for the Homebrew facet in each pane, owned here so the
    /// shared footer's Uninstall / Upgrade actions can read them.
    @State private var homebrewUninstallSelection: Set<BrewPackage.ID> = []
    @State private var homebrewUpdateSelection: Set<BrewOutdatedItem.ID> = []

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
        homebrewViewModel: HomebrewViewModel,
        result: ApplicationsScanResult,
        iconCache: AppIconCache,
        destination: Destination = .uninstaller,
        isPresented: Bool = true,
        onBack: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.uninstallerViewModel = uninstallerViewModel
        self.updaterViewModel = updaterViewModel
        self.extensionsManagerViewModel = extensionsManagerViewModel
        self.homebrewViewModel = homebrewViewModel
        self.result = result
        self.iconCache = iconCache
        self.destination = destination
        self.isPresented = isPresented
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
        // The title-bar safe-area extension is applied by ApplicationsView,
        // outside the manager zoom transition — see ManagerSurfaceModifier.
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
        // Feed Homebrew's outdated list into the Updater so cask-installed
        // apps appear as ordinary rows. Pushed rather than pulled: the
        // Homebrew view model is owned by ApplicationsView, and it has
        // already run the networked `brew outdated` — the Updater must not
        // run a second one. Keyed on the list so a later brew refresh (or
        // a completed upgrade) re-merges.
        .task(id: homebrewViewModel.outdated) {
            await homebrewViewModel.loadIfNeeded()
            await homebrewViewModel.checkUpdatesIfNeeded()
            updaterViewModel.setHomebrewOutdated(homebrewViewModel.outdated)
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
        // A retained manager (kept alive by its host between opens) re-aims
        // its panes on each open: a fresh instance resolves `destination` in
        // `init`, but a kept-alive one must follow it explicitly. Only the
        // three deep-link selections reset — other facets and the checkbox
        // selections survive, as they do across pane switches within one open.
        .onChange(of: isPresented) { _, presented in
            guard presented else { return }
            let (pane, facet, leftoverSection) = Self.resolve(destination)
            self.pane = pane
            self.uninstallerFacet = facet
            self.leftoverSection = leftoverSection
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

            // The Homebrew facets order by name and don't honor the app sort
            // options (they have no size/last-opened), so hide the control there
            // rather than leave it silently ineffective.
            if !isHomebrewFacetActive {
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
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// `true` when the visible pane is showing its Homebrew facet, whose lists
    /// are a separate data source that the app Sort options don't apply to.
    private var isHomebrewFacetActive: Bool {
        (pane == .uninstaller && uninstallerFacet == .homebrew)
            || (pane == .updater && updaterFacet == .homebrew)
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
                homebrewViewModel: homebrewViewModel,
                result: result,
                iconCache: iconCache,
                search: search,
                sort: sort,
                facet: $uninstallerFacet,
                inspectingAppID: $inspectingAppID,
                displayedApps: $displayedApps,
                homebrewSelection: $homebrewUninstallSelection
            )
        case .updater:
            UpdaterPaneView(
                updaterViewModel: updaterViewModel,
                homebrewViewModel: homebrewViewModel,
                iconCache: iconCache,
                search: search,
                facet: $updaterFacet,
                selection: $updateSelection,
                displayed: $displayedUpdates,
                homebrewSelection: $homebrewUpdateSelection
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
        case .uninstaller where uninstallerFacet == .homebrew:
            // The Homebrew facet removes brew packages via `brew uninstall`
            // (with a dependency check), not the Trash recycler.
            actionFooter(
                summary: homebrewUninstallSummary,
                actionLabel: String(localized: "Uninstall", comment: "Footer action removing the selected Homebrew packages."),
                enabled: !selectedHomebrewPackages.isEmpty && !homebrewViewModel.isBusy,
                identifier: "applications.manager.homebrew.uninstall"
            ) { Task { await homebrewViewModel.requestUninstall(selectedHomebrewPackages) } }
        case .uninstaller:
            actionFooter(
                summary: uninstallSummary,
                actionLabel: String(localized: "Uninstall", comment: "Footer action removing the selected apps."),
                enabled: uninstallerViewModel.canUninstallSelection,
                identifier: "applications.manager.uninstall"
            ) { showUninstallConfirmation = true }
        case .updater where updaterFacet == .homebrew:
            // The Homebrew facet upgrades brew packages via `brew upgrade`.
            actionFooter(
                summary: homebrewUpgradeSummary,
                actionLabel: String(localized: "Update", comment: "Footer action upgrading the selected Homebrew packages."),
                enabled: !selectedHomebrewUpgradeNames.isEmpty && !homebrewViewModel.isBusy,
                identifier: "applications.manager.homebrew.upgrade"
            ) { Task { await homebrewViewModel.upgrade(.some(selectedHomebrewUpgradeNames)) } }
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

    /// The selected brew packages to uninstall, resolved from the inventory.
    private var selectedHomebrewPackages: [BrewPackage] {
        homebrewViewModel.inventory.filter { homebrewUninstallSelection.contains($0.id) }
    }

    /// The selected outdated brew package names to upgrade, excluding pinned.
    private var selectedHomebrewUpgradeNames: [String] {
        homebrewViewModel.outdated
            .filter { homebrewUpdateSelection.contains($0.id) && !$0.isPinned }
            .map(\.name)
    }

    private var homebrewUninstallSummary: String {
        let count = selectedHomebrewPackages.count
        guard count > 0 else {
            return String(localized: "No Packages Selected", comment: "Homebrew uninstaller footer, nothing selected.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld Packages Selected", comment: "Homebrew uninstaller footer selected count."),
            Int64(count)
        )
    }

    private var homebrewUpgradeSummary: String {
        let count = selectedHomebrewUpgradeNames.count
        guard count > 0 else {
            return String(localized: "No Packages Selected", comment: "Homebrew updater footer, nothing selected.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld Packages Selected", comment: "Homebrew updater footer selected count."),
            Int64(count)
        )
    }

    /// Applies every selected update as one batch, routing each row to the
    /// mechanism that can actually install it: Homebrew-managed apps are
    /// upgraded in place, App Store entries collapse to a single Updates
    /// page, and remaining downloads open once each.
    private func updateSelected() async {
        let selected = updaterViewModel.availableUpdates.filter { updateSelection.contains($0.id) }
        let plan = updaterViewModel.updatePlan(for: selected)
        if !plan.openable.isEmpty {
            await updaterViewModel.update(plan.openable)
        }
        // Guarded because brew refuses to run two operations at once; the
        // Homebrew facet's own footer shares the same view model.
        if !plan.homebrewTokens.isEmpty, !homebrewViewModel.isBusy {
            await homebrewViewModel.upgrade(.some(plan.homebrewTokens))
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
