// ApplicationsView.swift
// Detail view for the Applications section — renders the post-scan dashboard grid and pushes to the reused App Updater / App Uninstaller screens.

import SwiftUI

/// Detail view shown when the user selects "Applications" in the sidebar and
/// runs the scan. The intro screen and floating Scan disc are supplied by
/// `ScannableSectionContent` + `ContentView`; this view owns the `.scanning`,
/// `.results`, and `.failed` phases.
///
/// The summary grid pushes to the existing `AppUpdaterView` and
/// `AppUninstallerView`, reused unchanged as detail screens — the new
/// `ApplicationsViewModel` only produces the dashboard metrics.
struct ApplicationsView: View {

    private var viewModel: ApplicationsViewModel
    private var uninstallerViewModel: AppUninstallerViewModel
    private var updaterViewModel: AppUpdaterViewModel

    /// Shared icon cache so the Unused / Unsupported review rows show each
    /// app's real icon instead of a generic glyph. Pre-loaded off the main
    /// thread by the review screens when they appear.
    @State private var iconCache = AppIconCache()

    /// Which screen the results surface is showing — the dashboard grid, or one
    /// of the pushed detail screens. Owned here so the selection survives the
    /// brief remount when the underlying detail view loads.
    @State private var detail: Detail = .dashboard

    /// The results surface's screens.
    private enum Detail {
        case dashboard
        case updates
        case manage
        case installationFiles
        case unsupported
        case unused
        case leftovers
    }

    init(
        viewModel: ApplicationsViewModel,
        uninstallerViewModel: AppUninstallerViewModel,
        updaterViewModel: AppUpdaterViewModel
    ) {
        self.viewModel = viewModel
        self.uninstallerViewModel = uninstallerViewModel
        self.updaterViewModel = updaterViewModel
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.applications.title)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            // Unreachable: ContentView shows the unified SectionIntroView while
            // the coordinator reports `.intro` (which `.idle` maps to), so the
            // detail view is never built in this phase. The arm stays only to
            // keep the switch exhaustive over `Phase`.
            EmptyView()
        case .scanning:
            ApplicationsProgressState()
        case .results(let result):
            resultsContent(result)
        case .failed(let message):
            ApplicationsFailedState(
                message: message,
                onTryAgain: { Task { await viewModel.scan() } }
            )
        }
    }

    @ViewBuilder
    private func resultsContent(_ result: ApplicationsScanResult) -> some View {
        switch detail {
        case .dashboard:
            // No ScrollView: the grid sizes its cards to the available height
            // so the whole dashboard fits the window without scrolling.
            ApplicationsDashboardView(
                result: result,
                onOpenUpdates: { detail = .updates },
                onOpenManage: { detail = .manage },
                onOpenInstallationFiles: { detail = .installationFiles },
                onOpenUnsupported: { detail = .unsupported },
                onOpenUnused: { detail = .unused },
                onOpenLeftovers: { detail = .leftovers },
                onRescan: { Task { await viewModel.scan() } }
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .updates:
            detailScreen(
                title: String(
                    localized: "Updates",
                    comment: "Title of the Applications Updates detail screen."
                )
            ) {
                AppUpdaterView(viewModel: updaterViewModel)
            }
        case .manage:
            // Full multi-pane manager (Uninstaller / Updater / Leftovers),
            // styled like the Optimization "View All Tasks" catalog — it owns
            // its own header, so it is not wrapped in `detailScreen`.
            ApplicationsManagerView(
                viewModel: viewModel,
                uninstallerViewModel: uninstallerViewModel,
                updaterViewModel: updaterViewModel,
                result: result,
                iconCache: iconCache,
                onBack: { detail = .dashboard }
            )
        case .installationFiles:
            detailScreen(
                title: String(
                    localized: "Installation Files",
                    comment: "Title of the Applications Installation Files detail screen."
                )
            ) {
                InstallationFilesReviewView(
                    files: result.installationFiles,
                    isSelected: viewModel.isInstallationFileSelected,
                    onToggle: viewModel.toggleInstallationFile,
                    onSelectAll: viewModel.selectAllInstallationFiles,
                    onClear: viewModel.clearInstallationFileSelection,
                    isRemoving: viewModel.isRemovingInstallationFiles,
                    canRemove: viewModel.canRemoveInstallationFiles,
                    onRemove: { Task { await viewModel.deleteSelectedInstallationFiles() } }
                )
            }
        case .unsupported:
            detailScreen(
                title: String(
                    localized: "Unsupported Applications",
                    comment: "Title of the Applications Unsupported detail screen."
                )
            ) {
                UnsupportedAppsReviewView(
                    apps: result.unsupportedApps,
                    iconCache: iconCache,
                    isSelected: viewModel.isUnsupportedAppSelected,
                    onToggle: viewModel.toggleUnsupportedApp,
                    onSelectAll: viewModel.selectAllUnsupportedApps,
                    onClear: viewModel.clearUnsupportedAppSelection,
                    isRemoving: viewModel.isRemovingUnsupportedApps,
                    canRemove: viewModel.canRemoveUnsupportedApps,
                    onRemove: { Task { await viewModel.deleteSelectedUnsupportedApps() } }
                )
            }
        case .unused:
            detailScreen(
                title: String(
                    localized: "Unused Applications",
                    comment: "Title of the Applications Unused detail screen."
                )
            ) {
                UnusedAppsReviewView(
                    apps: result.unusedApps,
                    iconCache: iconCache,
                    isSelected: viewModel.isUnusedAppSelected,
                    onToggle: viewModel.toggleUnusedApp,
                    onSelectAll: viewModel.selectAllUnusedApps,
                    onClear: viewModel.clearUnusedAppSelection,
                    isRemoving: viewModel.isRemovingUnusedApps,
                    canRemove: viewModel.canRemoveUnusedApps,
                    onRemove: { Task { await viewModel.deleteSelectedUnusedApps() } }
                )
            }
        case .leftovers:
            detailScreen(
                title: String(
                    localized: "App Leftovers",
                    comment: "Title of the Applications Leftovers detail screen."
                )
            ) {
                AppLeftoversReviewView(
                    groups: result.leftovers,
                    isSelected: viewModel.isLeftoverSelected,
                    onToggle: viewModel.toggleLeftover,
                    onSelectAll: viewModel.selectAllLeftovers,
                    onClear: viewModel.clearLeftoverSelection,
                    isRemoving: viewModel.isRemovingLeftovers,
                    canRemove: viewModel.canRemoveLeftovers,
                    onRemove: { Task { await viewModel.deleteSelectedLeftovers() } }
                )
            }
        }
    }

    /// Wraps a reused detail screen with a Back bar that returns to the grid.
    /// Mirrors `OptimizationTaskCatalogView`'s header layout.
    private func detailScreen<Content: View>(
        title: String,
        @ViewBuilder _ screen: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    detail = .dashboard
                } label: {
                    // HStack(Image, Text) rather than Label so the control
                    // surfaces reliably in XCUITest.
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(String(
                            localized: "Back",
                            comment: "Back button returning from an Applications detail screen to the dashboard."
                        ))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("applications.backToDashboard")
                Spacer()
                Text(title)
                    .font(.headline)
                Spacer()
                // Balances the leading Back button so the title stays centred.
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(16)
            Divider()
            screen()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The "Applications Manager" reached from the dashboard's Manage card. Mirrors
/// the Optimization "View All Tasks" catalog (`OptimizationTaskCatalogView`): a
/// header with a Back affordance and a centered title, a left sub-navigation,
/// and a detail pane. The three panes reuse the existing Uninstaller, Updater,
/// and Leftovers screens so all the management work lives in one place.
struct ApplicationsManagerView: View {

    private var viewModel: ApplicationsViewModel
    private var uninstallerViewModel: AppUninstallerViewModel
    private var updaterViewModel: AppUpdaterViewModel
    private let result: ApplicationsScanResult
    private var iconCache: AppIconCache
    private let onBack: () -> Void

    /// Which sub-section the manager is showing. Local state — it survives the
    /// view's re-renders while the manager is open, and resets when the user
    /// returns to the dashboard and comes back.
    @State private var pane: Pane = .uninstaller

    enum Pane: Hashable {
        case uninstaller
        case updater
        case leftovers
    }

    init(
        viewModel: ApplicationsViewModel,
        uninstallerViewModel: AppUninstallerViewModel,
        updaterViewModel: AppUpdaterViewModel,
        result: ApplicationsScanResult,
        iconCache: AppIconCache,
        onBack: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.uninstallerViewModel = uninstallerViewModel
        self.updaterViewModel = updaterViewModel
        self.result = result
        self.iconCache = iconCache
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                subNavigation
                    .frame(width: 220)
                    .padding(16)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.manager")
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: onBack) {
                // HStack(Image, Text) rather than Label so the control surfaces
                // reliably in XCUITest.
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(String(
                        localized: "Back",
                        comment: "Back button returning from the Applications Manager to the dashboard."
                    ))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("applications.backToDashboard")
            Spacer()
            Text(String(
                localized: "Applications Manager",
                comment: "Title of the Applications Manager catalog."
            ))
            .font(.headline)
            Spacer()
            // Balances the leading Back button so the title stays centred.
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(16)
    }

    // MARK: Sub-navigation

    private var subNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            navItem(.uninstaller,
                    String(localized: "Uninstaller", comment: "Applications Manager sub-nav item."),
                    "applications.manager.nav.uninstaller")
            navItem(.updater,
                    String(localized: "Updater", comment: "Applications Manager sub-nav item."),
                    "applications.manager.nav.updater")
            navItem(.leftovers,
                    String(localized: "Leftovers", comment: "Applications Manager sub-nav item."),
                    "applications.manager.nav.leftovers")
            Spacer()
        }
    }

    private func navItem(_ target: Pane, _ title: String, _ identifier: String) -> some View {
        Button {
            pane = target
        } label: {
            Text(title)
                .font(.body.weight(pane == target ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    pane == target ? Color.primary.opacity(0.10) : .clear,
                    in: .rect(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        switch pane {
        case .uninstaller:
            AppUninstallerView(viewModel: uninstallerViewModel, iconCache: iconCache)
        case .updater:
            AppUpdaterView(viewModel: updaterViewModel)
        case .leftovers:
            AppLeftoversReviewView(
                groups: result.leftovers,
                isSelected: viewModel.isLeftoverSelected,
                onToggle: viewModel.toggleLeftover,
                onSelectAll: viewModel.selectAllLeftovers,
                onClear: viewModel.clearLeftoverSelection,
                isRemoving: viewModel.isRemovingLeftovers,
                canRemove: viewModel.canRemoveLeftovers,
                onRemove: { Task { await viewModel.deleteSelectedLeftovers() } }
            )
        }
    }
}

#Preview {
    ApplicationsView(
        viewModel: ApplicationsViewModel(
            discoverApps: { [] },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [] },
            scanUnusedApps: { _ in [] },
            scanLeftovers: { _ in [] },
            recycleFiles: { Set($0) }
        ),
        uninstallerViewModel: AppUninstallerViewModel(
            discover: { _ in [] },
            findFiles: { _ in [] },
            recycle: { _, _ in AppUninstallerViewModel.RecycleOutcome(bytesFreed: 0, bundlePermanentlyRemoved: false) }
        ),
        updaterViewModel: AppUpdaterViewModel(
            discover: { _ in [] },
            checkAppStore: { _ in .noResult },
            checkSparkle: { _ in .noResult },
            opener: { _ in }
        )
    )
    .frame(width: 900, height: 600)
    .environment(ExclusionsStore(defaults: UserDefaults(suiteName: "preview")!))
}
