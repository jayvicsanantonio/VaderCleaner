// ContentView.swift
// Root scene composition — the navigation rail plus a section-keyed detail pane, with the floating Scan disc panel attached to the host window.

import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionOnboardingViewModel.self) private var onboarding
    @Environment(SystemStatsService.self) private var systemStats
    @Environment(NotificationThresholdMonitor.self) private var notificationMonitor
    @Environment(\.scenePhase) private var scenePhase
    private let systemJunkViewModel: SystemJunkViewModel
    private let largeOldFilesViewModel: LargeOldFilesViewModel
    private let spaceLensViewModel: DiskScannerViewModel
    private let spaceLensViewMode: SpaceLensViewModeStore
    private let privacyViewModel: PrivacyViewModel
    private let appUninstallerViewModel: AppUninstallerViewModel
    private let appUpdaterViewModel: AppUpdaterViewModel
    private let applicationsViewModel: ApplicationsViewModel
    private let extensionsManagerViewModel: ExtensionsManagerViewModel
    private let optimizationViewModel: OptimizationViewModel
    private let malwareViewModel: MalwareViewModel
    private let smartScanViewModel: SmartScanViewModel
    @State private var selectedSection: NavigationSection? = .smartScan
    /// Which way the detail pane's slide-and-fade transition should travel for
    /// the current section change. Set by `selectSection` from the rail order
    /// of the outgoing and incoming sections, just before the selection — and
    /// therefore the keyed animation — commits.
    @State private var navigationDirection: SectionTransitionDirection = .down
    /// The latest section a rail tap is steering toward while a previous
    /// `selectSection` is still waiting on its deferred commit. Coalesces
    /// rapid taps into one pending dispatch so the navigation lands on the
    /// final target — never an intermediate one — with the matching direction.
    @State private var pendingSelection: NavigationSection?
    /// Latched once the notification permission prompt has been issued for the
    /// session. Without this, an `.onChange` flurry (FDA refresh tick + sheet
    /// dismissal in the same cycle) would request authorization twice — the
    /// system caches the answer so the second prompt is a no-op, but it's
    /// cleaner to issue exactly one.
    @State private var didRequestNotificationPermission = false
    /// Fixed width of the navigation rail. Shared by the rail's own frame and
    /// the Scan disc panel so the disc centers over the detail content area
    /// (not the full window) without the two drifting apart.
    private let railWidth: CGFloat = 240
    /// Owns the borderless child panel that hosts the floating Scan disc so it
    /// can straddle the window's bottom edge. Created with the scannable view
    /// models; attached once the host window resolves.
    @State private var scanDiscController: ScanDiscWindowController
    init(
        systemJunkViewModel: SystemJunkViewModel,
        largeOldFilesViewModel: LargeOldFilesViewModel,
        spaceLensViewModel: DiskScannerViewModel,
        spaceLensViewMode: SpaceLensViewModeStore,
        privacyViewModel: PrivacyViewModel,
        appUninstallerViewModel: AppUninstallerViewModel,
        appUpdaterViewModel: AppUpdaterViewModel,
        applicationsViewModel: ApplicationsViewModel,
        extensionsManagerViewModel: ExtensionsManagerViewModel,
        optimizationViewModel: OptimizationViewModel,
        malwareViewModel: MalwareViewModel,
        smartScanViewModel: SmartScanViewModel
    ) {
        self.systemJunkViewModel = systemJunkViewModel
        self.largeOldFilesViewModel = largeOldFilesViewModel
        self.spaceLensViewModel = spaceLensViewModel
        self.spaceLensViewMode = spaceLensViewMode
        self.privacyViewModel = privacyViewModel
        self.appUninstallerViewModel = appUninstallerViewModel
        self.appUpdaterViewModel = appUpdaterViewModel
        self.applicationsViewModel = applicationsViewModel
        self.extensionsManagerViewModel = extensionsManagerViewModel
        self.optimizationViewModel = optimizationViewModel
        self.malwareViewModel = malwareViewModel
        self.smartScanViewModel = smartScanViewModel
        _scanDiscController = State(initialValue: ScanDiscWindowController(
            smartScanViewModel: smartScanViewModel,
            systemJunkViewModel: systemJunkViewModel,
            largeOldFilesViewModel: largeOldFilesViewModel,
            spaceLensViewModel: spaceLensViewModel,
            optimizationViewModel: optimizationViewModel,
            malwareViewModel: malwareViewModel,
            privacyViewModel: privacyViewModel,
            applicationsViewModel: applicationsViewModel
        ))
    }

    /// Colour identity of the section currently on screen. Drives the window
    /// backdrop and the control tint; falls back to Smart Scan's theme before
    /// a selection exists.
    private var theme: SectionTheme {
        (selectedSection ?? .smartScan).theme
    }

    var body: some View {
        HStack(spacing: 0) {
            NavigationRailView(
                selectedSection: selectedSection,
                onSelect: selectSection
            )
            .frame(width: railWidth)

            // Hosts `.navigationTitle` / `.toolbar` for the detail screens
            // without reintroducing a split divider.
            NavigationStack {
                // A plain ZStack hosts the section-keyed detail view so its
                // `.id`-driven swap has a stable parent to play its transition
                // within. NavigationStack is not a reliable transition host
                // for its own root content; wrapping in an everyday container
                // is the canonical SwiftUI pattern.
                ZStack {
                    detailView(for: selectedSection ?? .smartScan)
                        // Slide-and-fade the detail screen as the section
                        // changes, reading as a scroll between rows: a
                        // downward rail tap sends content sliding up (the
                        // outgoing screen exits through the top, the incoming
                        // follows up from the bottom), and an upward rail tap
                        // mirrors the motion in the opposite direction. Both
                        // halves of the transition travel the same way and
                        // run sequentially, so only one section is on screen
                        // at a time. `selectSection` updates
                        // `navigationDirection` a tick before the selection
                        // commits so both halves agree on the direction.
                        .id(selectedSection)
                        .transition(.sectionContent(navigationDirection))
                }
                // The transaction has to span the full sequential transition
                // (exit + entry delay + entry = ~1.1s). If it's shorter than
                // the insertion's `.delay`, SwiftUI cancels the deferred entry
                // animation and the incoming view snaps to its rest position
                // instead of sliding in. Slightly longer than the actual
                // total just gives a margin of safety.
                .animation(.smooth(duration: 1.2), value: selectedSection)
            }
        }
        // The floating Scan disc lives in its own borderless child panel
        // (`ScanDiscWindowController`) so it can straddle the window's bottom
        // edge — a plain overlay cannot, because a window clips its content.
        // Resolve the host window, then hand it to the controller.
        .background(
            WindowAccessor { window in
                scanDiscController.attach(
                    to: window,
                    railWidth: railWidth,
                    appState: appState
                )
            }
        )
        // Mirror the sidebar selection onto the disc panel so it shows the
        // matching section's disc.
        .onChange(of: selectedSection) { _, newValue in
            scanDiscController.section = newValue ?? .smartScan
        }
        // Animates the rail's section-change motion — chiefly the selection
        // pill sliding between rows. The detail pane and the backdrop each
        // animate their own transition with a matching curve.
        .animation(.smooth(duration: 0.42), value: selectedSection)
        // The side-by-side section intro needs a pane wide enough for the
        // hero, the gap, and the text column; a 1000pt minimum keeps that
        // fixed layout from clipping at the smallest allowed window width.
        .frame(minWidth: 1000, minHeight: 600)
        // Per-section gradient backdrop, keyed to the selection and crossfaded
        // on change so moving between sections recolours the whole window. The
        // toolbar background is hidden so the floating glass toolbar items sit
        // directly over the gradient instead of on a band.
        .background {
            VaderBackground(theme: theme)
                .id(selectedSection)
                .transition(.opacity)
                .animation(.smooth(duration: 0.55), value: selectedSection)
        }
        .vaderShell(accent: theme.accent)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: shouldShowOnboarding) {
            PermissionOnboardingView()
                .environment(appState)
                .environment(onboarding)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                appState.refresh()
            }
        }
        // Ask for notification permission only after the FDA onboarding has
        // settled — either the user already has Full Disk Access, or they
        // dismissed the sheet via "Continue Without Access". Stacking the
        // notification prompt on top of the FDA sheet would split the user's
        // attention between two consent dialogs and make it likely they'd
        // deny notifications without context.
        .task { await maybeRequestNotificationPermission() }
        .onChange(of: appState.hasFullDiskAccess) { _, _ in
            Task { await maybeRequestNotificationPermission() }
        }
        .onChange(of: onboarding.isDismissed) { _, _ in
            Task { await maybeRequestNotificationPermission() }
        }
        .onDisappear {
            spaceLensViewModel.cancelScan()
        }
    }

    /// Applies a sidebar selection, recording the travel direction first and
    /// then committing the selection on the next runloop tick. The deferral
    /// matters: SwiftUI resolves a removal transition from the outgoing
    /// view's last render, so a same-batch write of both `@State` values
    /// would leave the removal half stuck on the previous direction and the
    /// two halves of the slide would disagree on a reversal. To avoid the
    /// race condition that a naive dispatch would open up (rapid taps
    /// queuing intermediate selections, each animating with a later tap's
    /// direction), we coalesce: only one pending commit is ever in flight,
    /// and any further taps simply re-target it. The user always lands on
    /// the final tapped section, with the direction computed against the
    /// section they're actually leaving.
    private func selectSection(_ section: NavigationSection) {
        guard section != selectedSection else { return }
        guard let current = selectedSection else {
            selectedSection = section
            return
        }
        navigationDirection = current.transitionDirection(to: section)
        let wasIdle = pendingSelection == nil
        pendingSelection = section
        if wasIdle {
            DispatchQueue.main.async {
                if let target = pendingSelection {
                    pendingSelection = nil
                    selectedSection = target
                }
            }
        }
    }

    /// Idempotent permission-request driver. Fires the system prompt at most
    /// once per session, and only once the FDA onboarding flow has reached a
    /// terminal state (granted or explicitly dismissed).
    private func maybeRequestNotificationPermission() async {
        guard !didRequestNotificationPermission else { return }
        guard appState.hasFullDiskAccess || onboarding.isDismissed else { return }
        didRequestNotificationPermission = true
        await notificationMonitor.requestPermission()
    }

    /// Routes the selected sidebar section to its detail view. The switch is
    /// exhaustive over `NavigationSection` so adding a section is a compile-time
    /// prompt to wire its view here.
    @ViewBuilder
    private func detailView(for section: NavigationSection) -> some View {
        switch section {
        case .smartScan:
            ScannableSectionContent(coordinator: smartScanViewModel, section: section) {
                SmartScanView(
                    viewModel: smartScanViewModel,
                    // Review buttons inside the Smart Scan dashboard now
                    // push their own in-place manager screens; only the
                    // Optimization Review's "Open Optimization" link still
                    // hops to the standalone section. The other two
                    // selectSection calls disappear with the inline push.
                    onOpenOptimization: { selectSection(.optimization) }
                )
            }
        case .healthMonitor:
            HealthMonitorView(service: systemStats)
        case .systemJunk:
            ScannableSectionContent(coordinator: systemJunkViewModel, section: section) {
                SystemJunkView(viewModel: systemJunkViewModel)
            }
        case .largeOldFiles:
            ScannableSectionContent(coordinator: largeOldFilesViewModel, section: section) {
                LargeOldFilesView(viewModel: largeOldFilesViewModel)
            }
        case .spaceLens:
            ScannableSectionContent(coordinator: spaceLensViewModel, section: section) {
                SpaceLensView(viewModel: spaceLensViewModel, viewMode: spaceLensViewMode)
            }
        case .privacy:
            ScannableSectionContent(coordinator: privacyViewModel, section: section) {
                PrivacyView(viewModel: privacyViewModel)
            }
        case .applications:
            ScannableSectionContent(coordinator: applicationsViewModel, section: section) {
                ApplicationsView(
                    viewModel: applicationsViewModel,
                    uninstallerViewModel: appUninstallerViewModel,
                    updaterViewModel: appUpdaterViewModel
                )
            }
        case .extensions:
            ExtensionsManagerView(viewModel: extensionsManagerViewModel)
        case .optimization:
            ScannableSectionContent(coordinator: optimizationViewModel, section: section) {
                OptimizationView(viewModel: optimizationViewModel)
            }
        case .malwareRemoval:
            ScannableSectionContent(coordinator: malwareViewModel, section: section) {
                MalwareView(viewModel: malwareViewModel)
            }
        }
    }

    /// Shown until either FDA is granted (which the foreground refresh will detect)
    /// or the user dismisses for the session — either via the explicit "Continue
    /// Without Access" button or via Esc / programmatic sheet dismissal, both of
    /// which route through `viewModel.dismiss()` so the sheet stays suppressed.
    private var shouldShowOnboarding: Binding<Bool> {
        Binding(
            get: { !appState.hasFullDiskAccess && !onboarding.isDismissed },
            set: { newValue in
                if newValue == false { onboarding.dismiss() }
            }
        )
    }
}

private extension AnyTransition {
    /// Slide-and-fade for the detail pane. Both halves of the transition
    /// travel the same way, so it reads as a continuous scroll: a `.up`
    /// move sends the outgoing screen out through the top edge and the
    /// incoming screen up from the bottom; a `.down` move mirrors that
    /// through the opposite edges. The two halves run sequentially so only
    /// one section is on screen at a time. `selectSection` writes the
    /// direction a tick before the selection so the outgoing view
    /// re-renders with the new direction before SwiftUI resolves the
    /// removal half, keeping both halves in agreement on a reversal.
    static func sectionContent(_ direction: SectionTransitionDirection) -> AnyTransition {
        // Halves run back-to-back: removal animates from 0 → exitDuration,
        // and the insertion's `.delay` keeps the new view at its starting
        // edge until the outgoing has fully cleared. The durations are
        // generous enough that the long edge-to-edge travel reads as a
        // fluid glide rather than a sharp slide, and `exitDuration`
        // matches the backdrop's own crossfade so the new section begins
        // entering exactly when the backdrop has finished recolouring.
        let exitDuration: Double = 0.55
        let entryDuration: Double = 0.55
        let removalEdge: Edge = direction == .down ? .bottom : .top
        let insertionEdge: Edge = direction == .down ? .top : .bottom
        return .asymmetric(
            insertion: .move(edge: insertionEdge)
                .combined(with: .opacity)
                .animation(.smooth(duration: entryDuration).delay(exitDuration)),
            removal: .move(edge: removalEdge)
                .combined(with: .opacity)
                .animation(.smooth(duration: exitDuration))
        )
    }
}

#Preview {
    let stats = SystemStatsService(autostart: false)
    let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "preview")!)
    let exclusions = ExclusionsStore(defaults: UserDefaults(suiteName: "preview")!)
    let notificationManager = NotificationManager()
    return ContentView(
        systemJunkViewModel: SystemJunkViewModel.live(exclusions: exclusions),
        largeOldFilesViewModel: LargeOldFilesViewModel.live(exclusions: exclusions),
        spaceLensViewModel: DiskScannerViewModel.live(exclusions: exclusions),
        spaceLensViewMode: SpaceLensViewModeStore(defaults: UserDefaults(suiteName: "preview")!),
        privacyViewModel: PrivacyViewModel.live(),
        appUninstallerViewModel: AppUninstallerViewModel.live(exclusions: exclusions),
        appUpdaterViewModel: AppUpdaterViewModel.live(),
        applicationsViewModel: ApplicationsViewModel.live(),
        extensionsManagerViewModel: ExtensionsManagerViewModel.live(),
        optimizationViewModel: OptimizationViewModel.live(systemStats: stats, preferences: prefs),
        malwareViewModel: MalwareViewModel.live(
            dispatcher: notificationManager,
            preferences: prefs
        ),
        smartScanViewModel: SmartScanViewModel.live(exclusions: exclusions)
    )
        .environment(AppState(checker: { true }))
        .environment(PermissionOnboardingViewModel())
        .environment(stats)
        .environment(NotificationThresholdMonitor(
            stats: stats,
            preferences: prefs,
            dispatcher: notificationManager
        ))
}
