// ContentView.swift
// Root scene composition — the navigation rail plus a section-keyed detail pane, with the floating Scan disc panel attached to the host window.

import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionOnboardingViewModel.self) private var onboarding
    @Environment(SystemStatsService.self) private var systemStats
    @Environment(NotificationThresholdMonitor.self) private var notificationMonitor
    @Environment(MenuRouter.self) private var menuRouter
    @Environment(\.scenePhase) private var scenePhase
    private let systemJunkViewModel: SystemJunkViewModel
    private let myClutterViewModel: MyClutterViewModel
    private let spaceLensViewModel: DiskScannerViewModel
    private let spaceLensViewMode: SpaceLensViewModeStore
    private let privacyViewModel: PrivacyViewModel
    private let appUninstallerViewModel: AppUninstallerViewModel
    private let appUpdaterViewModel: AppUpdaterViewModel
    private let applicationsViewModel: ApplicationsViewModel
    private let extensionsManagerViewModel: ExtensionsManagerViewModel
    private let performanceViewModel: PerformanceViewModel
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
    /// Width of the navigation rail when it shows icons + labels (the intro /
    /// landing layout).
    private let expandedRailWidth: CGFloat = 240
    /// Width of the rail when collapsed to icons only — narrow enough to read as
    /// a glyph rail while still fitting the selection pill around each icon.
    private let collapsedRailWidth: CGFloat = 76
    /// Current rail width. Shared by the rail's own frame and the Scan disc
    /// panel so the disc centers over the detail content area (not the full
    /// window) without the two drifting apart. Collapses once the selected
    /// section leaves its intro.
    private var railWidth: CGFloat { isRailCollapsed ? collapsedRailWidth : expandedRailWidth }

    /// The coarse scan phase of the section currently on screen, or `nil` for a
    /// non-scannable section (Health Monitor) that has no scan flow.
    private var activeScanPresentation: ScanPresentation? {
        switch selectedSection ?? .smartScan {
        case .smartScan:      return smartScanViewModel.scanPresentation
        case .systemJunk:     return systemJunkViewModel.scanPresentation
        case .largeOldFiles:  return myClutterViewModel.scanPresentation
        case .spaceLens:      return spaceLensViewModel.scanPresentation
        case .privacy:        return privacyViewModel.scanPresentation
        case .applications:   return applicationsViewModel.scanPresentation
        case .performance:   return performanceViewModel.scanPresentation
        case .malwareRemoval: return malwareViewModel.scanPresentation
        case .healthMonitor:  return nil
        }
    }

    /// The rail collapses to icons only once the selected section leaves its
    /// intro — i.e. right after the user taps Scan — and re-expands when it
    /// returns to the intro (Start Over). Non-scannable sections keep the
    /// expanded rail.
    private var isRailCollapsed: Bool {
        guard let presentation = activeScanPresentation else { return false }
        return presentation != .intro
    }
    /// Owns the borderless child panel that hosts the floating Scan disc so it
    /// can straddle the window's bottom edge. Created with the scannable view
    /// models; attached once the host window resolves.
    @State private var scanDiscController: ScanDiscWindowController
    init(
        systemJunkViewModel: SystemJunkViewModel,
        myClutterViewModel: MyClutterViewModel,
        spaceLensViewModel: DiskScannerViewModel,
        spaceLensViewMode: SpaceLensViewModeStore,
        privacyViewModel: PrivacyViewModel,
        appUninstallerViewModel: AppUninstallerViewModel,
        appUpdaterViewModel: AppUpdaterViewModel,
        applicationsViewModel: ApplicationsViewModel,
        extensionsManagerViewModel: ExtensionsManagerViewModel,
        performanceViewModel: PerformanceViewModel,
        malwareViewModel: MalwareViewModel,
        smartScanViewModel: SmartScanViewModel
    ) {
        self.systemJunkViewModel = systemJunkViewModel
        self.myClutterViewModel = myClutterViewModel
        self.spaceLensViewModel = spaceLensViewModel
        self.spaceLensViewMode = spaceLensViewMode
        self.privacyViewModel = privacyViewModel
        self.appUninstallerViewModel = appUninstallerViewModel
        self.appUpdaterViewModel = appUpdaterViewModel
        self.applicationsViewModel = applicationsViewModel
        self.extensionsManagerViewModel = extensionsManagerViewModel
        self.performanceViewModel = performanceViewModel
        self.malwareViewModel = malwareViewModel
        self.smartScanViewModel = smartScanViewModel
        _scanDiscController = State(initialValue: ScanDiscWindowController(
            smartScanViewModel: smartScanViewModel,
            systemJunkViewModel: systemJunkViewModel,
            myClutterViewModel: myClutterViewModel,
            spaceLensViewModel: spaceLensViewModel,
            performanceViewModel: performanceViewModel,
            malwareViewModel: malwareViewModel,
            privacyViewModel: privacyViewModel,
            applicationsViewModel: applicationsViewModel
        ))
        // When a Smart Scan completes, populate every standalone section so the
        // user never has to scan a section by hand after a Smart Scan.
        //
        // System Junk, Large & Old Files, and Malware run the exact same
        // scanners Smart Scan already used, so they're seeded with the results
        // directly — instant, no extra work.
        //
        // Applications and Performance need heavier, multi-step scans that
        // Smart Scan does not perform (full app analysis: updates, unused,
        // unsupported, leftovers, installers; and launch agents / RAM /
        // snapshots). Rather than show partial data, kick off each section's own
        // full scan now so it finishes in the background and is ready by the
        // time the user opens it.
        //
        // Every section is only populated when it is still idle, so this never
        // disrupts a section the user has already scanned themselves.
        smartScanViewModel.onScanCompleted = { [systemJunkViewModel, myClutterViewModel, malwareViewModel, applicationsViewModel, performanceViewModel] result in
            systemJunkViewModel.seed(with: result.junkResult)
            malwareViewModel.seed(
                threats: result.threats,
                clamAVAvailable: result.clamAVAvailable,
                scannedAt: Date()
            )
            // The My Clutter section runs four composite scans Smart Scan
            // doesn't produce, so it can't be seeded from the result — kick off
            // its own scan instead, like the other sections below.
            if case .idle = myClutterViewModel.phase { myClutterViewModel.beginScan() }
            if case .idle = applicationsViewModel.phase { applicationsViewModel.beginScan() }
            if case .idle = performanceViewModel.phase { performanceViewModel.beginScan() }
        }
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
                onSelect: selectSection,
                collapsed: isRailCollapsed
            )
            .frame(width: railWidth)
            // Slide the rail between its expanded and icons-only widths when the
            // selected section enters/leaves its scan.
            .animation(.smooth(duration: 0.32), value: railWidth)

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
        // Float the hovered collapsed-rail row's name beside it. Read at this
        // level (not inside the rail) so the bubble draws over the detail pane
        // and isn't clipped by the narrow rail or its ScrollView.
        .overlayPreferenceValue(RailTooltipPreferenceKey.self) { tooltip in
            GeometryReader { proxy in
                if let tooltip {
                    let rect = proxy[tooltip.bounds]
                    RailIconTooltip(title: tooltip.title)
                        .offset(x: rect.maxX + 8, y: rect.midY - RailIconTooltip.height / 2)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
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
        // Keep the floating disc centered over the detail area as the rail
        // collapses/expands — its placement is computed from the rail width.
        .onChange(of: railWidth) { _, newWidth in
            scanDiscController.setRailWidth(newWidth)
        }
        // Animates the rail's section-change motion — chiefly the selection
        // pill sliding between rows. The detail pane and the backdrop each
        // animate their own transition with a matching curve.
        .animation(.smooth(duration: 0.42), value: selectedSection)
        // The side-by-side section intro needs a pane wide enough for the
        // hero, the gap, and the text column; the minimum keeps that fixed
        // layout comfortable — not just un-clipped — at the smallest allowed
        // window width.
        // The minimum height is kept above the navigation rail's natural content
        // height (top inset + nine rows + gaps + bottom inset) so the last rail
        // icon always keeps a comfortable gap to the window's bottom edge, even
        // at the smallest allowed size.
        .frame(minWidth: 1140, minHeight: 640)
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
        // Consume any deep-link the menu bar panel recorded. Handled both on
        // appear (window was just opened/created by the menu) and on change
        // (window already open when the menu fired the request).
        .onAppear { applyPendingRoute() }
        .onChange(of: menuRouter.requestedSection) { _, _ in applyPendingRoute() }
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

    /// Applies a pending deep-link from the menu bar panel: navigates to the
    /// requested section and, when asked, begins that section's scan. Clears the
    /// request so it fires exactly once. No-op when nothing is pending.
    private func applyPendingRoute() {
        guard let target = menuRouter.requestedSection else { return }
        let startScan = menuRouter.requestStartScan
        menuRouter.requestedSection = nil
        menuRouter.requestStartScan = false

        selectSection(target)

        // Only Smart Scan auto-starts from the menu's "Run Smart Scan" — the
        // other deep-links just reveal the section and let the user act.
        if startScan, target == .smartScan {
            smartScanViewModel.beginScan()
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
                    // Performance Review's "Open Performance" link still
                    // hops to the standalone section. The other two
                    // selectSection calls disappear with the inline push.
                    onOpenPerformance: { selectSection(.performance) }
                )
            }
        case .healthMonitor:
            HealthMonitorView(service: systemStats)
        case .systemJunk:
            ScannableSectionContent(coordinator: systemJunkViewModel, section: section) {
                SystemJunkView(viewModel: systemJunkViewModel)
            }
        case .largeOldFiles:
            ScannableSectionContent(coordinator: myClutterViewModel, section: section) {
                MyClutterView(viewModel: myClutterViewModel)
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
                    updaterViewModel: appUpdaterViewModel,
                    extensionsManagerViewModel: extensionsManagerViewModel
                )
            }
        case .performance:
            ScannableSectionContent(coordinator: performanceViewModel, section: section) {
                PerformanceView(viewModel: performanceViewModel)
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
    let myClutterScanScope = MyClutterScanScopeStore(defaults: UserDefaults(suiteName: "preview")!)
    let notificationManager = NotificationManager()
    return ContentView(
        systemJunkViewModel: SystemJunkViewModel.live(exclusions: exclusions),
        myClutterViewModel: MyClutterViewModel.live(
            exclusions: exclusions,
            scanScope: myClutterScanScope
        ),
        spaceLensViewModel: DiskScannerViewModel.live(exclusions: exclusions),
        spaceLensViewMode: SpaceLensViewModeStore(defaults: UserDefaults(suiteName: "preview")!),
        privacyViewModel: PrivacyViewModel.live(),
        appUninstallerViewModel: AppUninstallerViewModel.live(exclusions: exclusions),
        appUpdaterViewModel: AppUpdaterViewModel.live(),
        applicationsViewModel: ApplicationsViewModel.live(),
        extensionsManagerViewModel: ExtensionsManagerViewModel.live(),
        performanceViewModel: PerformanceViewModel.live(systemStats: stats, preferences: prefs),
        malwareViewModel: MalwareViewModel.live(
            dispatcher: notificationManager,
            preferences: prefs
        ),
        smartScanViewModel: SmartScanViewModel.live(
            exclusions: exclusions,
            settings: SmartScanSettingsStore(defaults: UserDefaults(suiteName: "preview")!)
        )
    )
        .environment(AppState(checker: { true }))
        .environment(SmartScanSettingsStore(defaults: UserDefaults(suiteName: "preview")!))
        .environment(PermissionOnboardingViewModel())
        .environment(stats)
        .environment(NotificationThresholdMonitor(
            stats: stats,
            preferences: prefs,
            dispatcher: notificationManager
        ))
        .environment(MenuRouter())
}
