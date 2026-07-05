// ApplicationsView.swift
// Detail view for the Applications section — renders the post-scan dashboard grid and pushes into the Applications Manager screens.

import SwiftUI

/// Detail view shown when the user selects "Applications" in the sidebar and
/// runs the scan. The intro screen and floating Scan disc are supplied by
/// `ScannableSectionContent` + `ContentView`; this view owns the `.scanning`,
/// `.results`, and `.failed` phases.
///
/// The summary grid pushes into `ApplicationsManagerView`, opened on a
/// specific pane, as its detail screens — the new `ApplicationsViewModel`
/// only produces the dashboard metrics.
struct ApplicationsView: View {

    private var viewModel: ApplicationsViewModel
    private var uninstallerViewModel: AppUninstallerViewModel
    private var updaterViewModel: AppUpdaterViewModel
    private var extensionsManagerViewModel: ExtensionsManagerViewModel

    /// Shared icon cache so the Unused / Unsupported review rows show each
    /// app's real icon instead of a generic glyph. Pre-loaded off the main
    /// thread by the review screens when they appear.
    @State private var iconCache = AppIconCache()

    /// Which screen the results surface is showing — the dashboard grid, or one
    /// of the pushed detail screens. Owned here so the selection survives the
    /// brief remount when the underlying detail view loads.
    @State private var detail: Detail = .dashboard

    /// The results surface's screens: the dashboard grid, or the full Manager
    /// opened on a specific destination. Every card's Review button deep-links
    /// into the Manager rather than pushing its own review screen, so the Manage
    /// button and the cards share one manager surface.
    private enum Detail {
        case dashboard
        case manage(ApplicationsManagerView.Destination)
    }

    init(
        viewModel: ApplicationsViewModel,
        uninstallerViewModel: AppUninstallerViewModel,
        updaterViewModel: AppUpdaterViewModel,
        extensionsManagerViewModel: ExtensionsManagerViewModel
    ) {
        self.viewModel = viewModel
        self.uninstallerViewModel = uninstallerViewModel
        self.updaterViewModel = updaterViewModel
        self.extensionsManagerViewModel = extensionsManagerViewModel
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
            // The dashboard divides the pane height into a hero banner and a
            // grid of equal-height tiles, so it fills the detail area without a
            // scroll view.
            ApplicationsDashboardView(
                result: result,
                iconCache: iconCache,
                accent: NavigationSection.applications.theme.accent,
                onOpenManage: { detail = .manage(.uninstaller) },
                onOpenInstallationFiles: { detail = .manage(.installationFiles) },
                onOpenUnsupported: { detail = .manage(.unsupported) },
                onOpenUnused: { detail = .manage(.unused) },
                onOpenUpdates: { detail = .manage(.updater) },
                onOpenLeftovers: { detail = .manage(.leftovers) },
                onRemoveLeftovers: {
                    viewModel.selectAllLeftovers()
                    Task { await viewModel.deleteSelectedLeftovers() }
                }
            )
            // Generous top and bottom insets so the section breathes above the
            // hero and below the cards rather than running into the window edges.
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .manage(let destination):
            // Full multi-pane manager (Uninstaller / Updater / Extensions /
            // Leftovers / Unsupported), styled like the Performance "View All
            // Tasks" catalog — it owns its own header. Opens on `destination` so
            // each card's Review deep-links straight to the pane and facet where
            // its finding lives.
            ApplicationsManagerView(
                viewModel: viewModel,
                uninstallerViewModel: uninstallerViewModel,
                updaterViewModel: updaterViewModel,
                extensionsManagerViewModel: extensionsManagerViewModel,
                result: result,
                iconCache: iconCache,
                destination: destination,
                onBack: { detail = .dashboard }
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
        ),
        extensionsManagerViewModel: ExtensionsManagerViewModel(
            discover: { [] },
            remove: { _ in }
        )
    )
    .frame(width: 900, height: 600)
    .environment(ExclusionsStore(defaults: UserDefaults(suiteName: "preview")!))
}
