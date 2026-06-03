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
            ScrollView {
                ApplicationsDashboardView(
                    result: result,
                    onOpenUpdates: { detail = .updates },
                    onOpenManage: { detail = .manage },
                    onOpenInstallationFiles: { detail = .installationFiles },
                    onOpenUnsupported: { detail = .unsupported },
                    onOpenUnused: { detail = .unused },
                    onRescan: { Task { await viewModel.scan() } }
                )
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            detailScreen(
                title: String(
                    localized: "Manage Applications",
                    comment: "Title of the Applications management detail screen."
                )
            ) {
                AppUninstallerView(viewModel: uninstallerViewModel)
            }
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
                    isSelected: viewModel.isUnusedAppSelected,
                    onToggle: viewModel.toggleUnusedApp,
                    onSelectAll: viewModel.selectAllUnusedApps,
                    onClear: viewModel.clearUnusedAppSelection,
                    isRemoving: viewModel.isRemovingUnusedApps,
                    canRemove: viewModel.canRemoveUnusedApps,
                    onRemove: { Task { await viewModel.deleteSelectedUnusedApps() } }
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

#Preview {
    ApplicationsView(
        viewModel: ApplicationsViewModel(
            discoverApps: { [] },
            checkUpdates: { _ in [] },
            scanInstallationFiles: { [] },
            scanUnsupportedApps: { _ in [] },
            scanUnusedApps: { _ in [] },
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
