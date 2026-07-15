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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which screen the results surface is showing — the dashboard grid, or one
    /// of the pushed detail screens. Owned here so the selection survives the
    /// brief remount when the underlying detail view loads.
    @State private var detail: Detail = .dashboard
    /// Where the manager zoom anchors: the button that opened it, resolved
    /// by `openManager`. Also the point Back zooms the manager back into.
    @State private var managerAnchor: UnitPoint = .center
    /// The transition host's frame in global space, for mapping the opening
    /// click to `managerAnchor`.
    @State private var paneFrame = FrameBox()
    /// The title-bar safe-area inset the transition host permanently claims;
    /// handed back to the dashboard as top padding so only the manager
    /// extends under the title bar.
    @State private var paneTopInset: CGFloat = 0

    /// The results surface's screens: the dashboard grid, or the full Manager
    /// opened on a specific destination. Every card's Review button deep-links
    /// into the Manager rather than pushing its own review screen, so the Manage
    /// button and the cards share one manager surface.
    /// Equatable so the dashboard ↔ manager swap can key its transition
    /// animation on the current screen.
    private enum Detail: Equatable {
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

    /// The dashboard and the manager exchange inside a ZStack (a stable
    /// transition host) with the shared manager motion: the manager zooms up
    /// from the button that opened it over the receding dashboard, and zooms
    /// back into it on Back.
    @ViewBuilder
    private func resultsContent(_ result: ApplicationsScanResult) -> some View {
        ZStack {
            switch detail {
            case .dashboard:
                // The dashboard divides the pane height into a hero banner and a
                // grid of equal-height tiles, so it fills the detail area without a
                // scroll view.
                ApplicationsDashboardView(
                    result: result,
                    iconCache: iconCache,
                    accent: NavigationSection.applications.theme.accent,
                    onOpenManage: { openManager(.uninstaller) },
                    onOpenInstallationFiles: { openManager(.installationFiles) },
                    onOpenUnsupported: { openManager(.unsupported) },
                    onOpenUnused: { openManager(.unused) },
                    onOpenUpdates: { openManager(.updater) },
                    onOpenLeftovers: { openManager(.leftovers) },
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
                // The dashboard keeps its usual place below the title bar:
                // the host ZStack claims that inset permanently, so it is
                // handed back here as explicit padding.
                .padding(.top, paneTopInset)
                .transition(VaderMotion.dashboardTransition(reduceMotion: reduceMotion))
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
                .transition(VaderMotion.managerTransition(anchor: managerAnchor, reduceMotion: reduceMotion))
                // Draw over the dashboard while the two overlap mid-swap.
                .zIndex(1)
            }
        }
        // Claim the title-bar safe area on this stable container, never on a
        // transitioning branch: safe-area changes anywhere inside a freshly
        // inserted transition subtree are deferred until its spring fully
        // settles, which read as the manager stuck below a title-bar-height
        // gap for a beat after opening.
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame.rect = $0 })
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { paneTopInset = $0 })
        .animation(VaderMotion.managerZoom, value: detail)
    }

    /// Anchors the zoom to the button (or failing that, the click) being
    /// handled, then raises the manager on `destination`.
    private func openManager(_ destination: ApplicationsManagerView.Destination) {
        managerAnchor = TriggerAnchor.resolve(in: paneFrame.rect)
        detail = .manage(destination)
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
