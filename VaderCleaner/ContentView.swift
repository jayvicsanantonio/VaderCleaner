// ContentView.swift
// Root view — NavigationSplitView with sidebar listing all 11 sections and placeholder detail views.

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var onboarding: PermissionOnboardingViewModel
    @EnvironmentObject private var systemStats: SystemStatsService
    @EnvironmentObject private var notificationMonitor: NotificationThresholdMonitor
    @Environment(\.scenePhase) private var scenePhase
    private let systemJunkViewModel: SystemJunkViewModel
    private let largeOldFilesViewModel: LargeOldFilesViewModel
    private let spaceLensViewModel: DiskScannerViewModel
    private let privacyViewModel: PrivacyViewModel
    private let appUninstallerViewModel: AppUninstallerViewModel
    private let appUpdaterViewModel: AppUpdaterViewModel
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
    /// Namespace for the sliding selection pill in the custom rail.
    @Namespace private var pillNamespace
    /// The section the pointer is currently over, if any. Drives the rail's
    /// hover highlight — a quieter pill than the selection's.
    @State private var hoveredSection: NavigationSection?
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
    @StateObject private var scanDiscController: ScanDiscWindowController
    init(
        systemJunkViewModel: SystemJunkViewModel,
        largeOldFilesViewModel: LargeOldFilesViewModel,
        spaceLensViewModel: DiskScannerViewModel,
        privacyViewModel: PrivacyViewModel,
        appUninstallerViewModel: AppUninstallerViewModel,
        appUpdaterViewModel: AppUpdaterViewModel,
        extensionsManagerViewModel: ExtensionsManagerViewModel,
        optimizationViewModel: OptimizationViewModel,
        malwareViewModel: MalwareViewModel,
        smartScanViewModel: SmartScanViewModel
    ) {
        self.systemJunkViewModel = systemJunkViewModel
        self.largeOldFilesViewModel = largeOldFilesViewModel
        self.spaceLensViewModel = spaceLensViewModel
        self.privacyViewModel = privacyViewModel
        self.appUninstallerViewModel = appUninstallerViewModel
        self.appUpdaterViewModel = appUpdaterViewModel
        self.extensionsManagerViewModel = extensionsManagerViewModel
        self.optimizationViewModel = optimizationViewModel
        self.malwareViewModel = malwareViewModel
        self.smartScanViewModel = smartScanViewModel
        _scanDiscController = StateObject(wrappedValue: ScanDiscWindowController(
            smartScanViewModel: smartScanViewModel,
            systemJunkViewModel: systemJunkViewModel,
            largeOldFilesViewModel: largeOldFilesViewModel,
            spaceLensViewModel: spaceLensViewModel,
            optimizationViewModel: optimizationViewModel,
            malwareViewModel: malwareViewModel,
            privacyViewModel: privacyViewModel
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
            // A custom rail of buttons (not a List) so selection can be a soft
            // inset glass pill with generous spacing instead of the system's
            // full-bleed selection bar. The rail and detail share one
            // continuous gradient — no sidebar material, no divider.
            rail
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
                        // Slide-and-fade the incoming detail screen: it drifts
                        // in from above for a lower rail row and from below
                        // for a higher one, so navigation has a sense of
                        // direction. The outgoing screen only fades — a
                        // transition's removal half is resolved a render
                        // before its insertion half, so a direction-free
                        // removal avoids the two halves disagreeing on a
                        // change of travel direction. `selectSection` sets
                        // `navigationDirection` before the selection commits.
                        .id(selectedSection)
                        .transition(.sectionContent(navigationDirection))
                }
                .animation(.smooth(duration: 0.42), value: selectedSection)
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
                .environmentObject(appState)
                .environmentObject(onboarding)
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

    /// The navigation rail: one button per section with a soft glass
    /// selection pill that marks the active row. Arrow-key navigation between
    /// rows is intentionally not reimplemented (it was a `List` affordance);
    /// the rows are focusable buttons, so Tab / Space / Return and VoiceOver
    /// still work.
    private var rail: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(NavigationSection.allCases) { section in
                    railRow(section)
                }
            }
            .padding(.horizontal, 10)
            // The content extends under the hidden title bar, so inset the
            // first row clear of the window's traffic-light controls. The top
            // and bottom insets, the row gap, and the row height are tuned
            // together so all eleven rows fit a default-height window without
            // scrolling.
            .padding(.top, 58)
            .padding(.bottom, 12)
        }
        // No scroll indicator: at a typical window height the eleven rows sit
        // statically with no visible scrolling. The ScrollView is retained so
        // the bottom rows stay reachable when a short window or a larger
        // Dynamic Type size overflows the column.
        .scrollIndicators(.hidden)
        // Anchor the rail to the true window top. Detail screens declare
        // different toolbars, which changes the window's top safe-area inset;
        // without this the rail would ride that inset and shift vertically
        // between sections. The `.padding(.top, 44)` above clears the
        // traffic-light controls measured from this fixed top.
        .ignoresSafeArea(.container, edges: .top)
    }

    private func railRow(_ section: NavigationSection) -> some View {
        let isSelected = selectedSection == section
        let isHovering = hoveredSection == section
        return Button {
            selectSection(section)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: section.icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    // The icon stays neutral — matching the inactive label —
                    // until the row is active or hovered, when it lights up in
                    // the section's accent.
                    .foregroundStyle(
                        isSelected || isHovering
                            ? section.theme.accent
                            : Color.white.opacity(0.62)
                    )
                    .frame(width: 26)
                Text(section.title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected || isHovering ? Color.white : Color.white.opacity(0.62))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background {
                if isSelected {
                    // A translucent pill — the dark page shows through, lifted
                    // by a soft horizontal sheen that is brightest at the left
                    // and right edges and dims behind the label in the centre.
                    // No accent tint: a saturated glass fill reads as a solid
                    // button, not the see-through surface the reference uses.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.22),
                                    .white.opacity(0.07),
                                    .white.opacity(0.22),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .overlay {
                            // A hairline rim in the section's accent, brightest
                            // along the leading edge and fading across to the
                            // trailing edge, so the active pill reads as a lit,
                            // colour-keyed glass surface.
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            section.theme.accent.opacity(0.85),
                                            section.theme.accent.opacity(0.25),
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .matchedGeometryEffect(id: "selectionPill", in: pillNamespace)
                } else if isHovering {
                    // Hover highlight — a quieter pill than the selection: a
                    // fainter flat fill and a dim hairline border, no top-lit
                    // sheen, so the hover and active states stay clearly
                    // distinct.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Suppress the macOS keyboard focus ring. Without this the first
        // focusable row wears the system's blue halo on launch; the rail's
        // selection pill is its own state indicator.
        .focusEffectDisabled()
        // Track the pointer so the row can show its hover highlight. Clearing
        // only when *this* section is the one being left avoids a stale value
        // when the pointer crosses straight from one row to the next.
        .onHover { hovering in
            if hovering {
                hoveredSection = section
            } else if hoveredSection == section {
                hoveredSection = nil
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityIdentifier(section.accessibilityIdentifier)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Applies a sidebar selection, first recording which way the detail pane
    /// should travel so its slide-and-fade transition matches the rail move.
    /// Both `@State` writes land in one update pass, so the keyed animation
    /// drives the transition with the direction already in place. Every
    /// selection change — rail taps and the Smart Scan review shortcuts —
    /// routes through here so the direction is never stale.
    private func selectSection(_ section: NavigationSection) {
        guard section != selectedSection else { return }
        if let current = selectedSection {
            navigationDirection = current.transitionDirection(to: section)
        }
        selectedSection = section
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
                    onReviewSystemJunk: { selectSection(.systemJunk) },
                    onReviewMalware: { selectSection(.malwareRemoval) },
                    onReviewOptimization: { selectSection(.optimization) }
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
                SpaceLensView(viewModel: spaceLensViewModel)
            }
        case .privacy:
            ScannableSectionContent(coordinator: privacyViewModel, section: section) {
                PrivacyView(viewModel: privacyViewModel)
            }
        case .appUninstaller:
            AppUninstallerView(viewModel: appUninstallerViewModel)
        case .appUpdater:
            AppUpdaterView(viewModel: appUpdaterViewModel)
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
    /// Slide-and-fade for the detail pane. The incoming screen drifts into
    /// place from above for a `.down` move and from below for an `.up` one, so
    /// the new content visibly travels the way the rail selection moved. The
    /// outgoing screen only fades: a transition's removal half is resolved a
    /// render before its insertion half, so a direction-free removal stops a
    /// change of travel direction from leaving the two halves sliding opposite
    /// ways.
    static func sectionContent(_ direction: SectionTransitionDirection) -> AnyTransition {
        // A modest drift — the fade carries the transition, the offset only
        // gives it a direction.
        let distance: CGFloat = 60
        let travel: CGFloat = direction == .down ? distance : -distance
        return .asymmetric(
            insertion: .offset(y: -travel).combined(with: .opacity),
            removal: .opacity
        )
    }
}

/// Gates a scannable section between the unified `SectionIntroView` and its
/// own detail view. The coordinator is held as `@ObservedObject` here — not in
/// ContentView, where the view models are plain `let`s — so the swap is
/// reactive: tapping the floating Scan flips `scanPresentation` off `.intro`
/// and this view rebuilds into the detail view. The detail closure is not
/// evaluated while at `.intro`, so the section's auto-load `.task`/`.onAppear`
/// stays gated behind Scan rather than firing under the intro.
private struct ScannableSectionContent<Coordinator: ScanCoordinating, Detail: View>: View {
    @ObservedObject var coordinator: Coordinator
    let section: NavigationSection
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        // A plain ZStack so the body's root carries no `.transition` of its
        // own. The intro↔scan crossfade lives one level in, on `content`;
        // keeping it off the root lets the outer section-navigation slide
        // (applied to this view by `ContentView`) act on a clean container
        // instead of colliding with this wrapper's own transition.
        ZStack {
            content
                // Reuse SmartScanView's phase-transition pattern so the
                // intro → scan swap crossfades instead of hard-cutting.
                .id(phaseTransitionID)
                .transition(.opacity)
                .animation(.smooth(duration: 0.35), value: phaseTransitionID)
        }
    }

    /// Binary token: only the intro ↔ detail boundary crossfades. It is
    /// deliberately *not* the full three-state `ScanPresentation` — `.working`
    /// and `.results` both render `detail()`, so distinguishing them here
    /// would change the view identity on the working → results boundary and
    /// rebuild the live detail view mid-scan (re-running its `.task`/`onAppear`
    /// and dropping in-progress state). The detail view owns its own
    /// working → results transition; `SmartScanView` already crossfades its
    /// internal phases with this same pattern.
    private var phaseTransitionID: String {
        coordinator.scanPresentation == .intro ? "intro" : "detail"
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.scanPresentation == .intro,
           let presentation = SectionPresentation.for(section) {
            SectionIntroView(presentation: presentation, section: section)
        } else {
            // `.working`/`.results`, or the defensive case of a scannable
            // section with no presentation metadata: the section's own
            // detail view is the source of truth for every non-intro phase.
            detail()
        }
    }
}

/// Resolves the `NSWindow` hosting a SwiftUI view. SwiftUI exposes no direct
/// handle to its window, so this zero-size representable reads `view.window`
/// once the view joins the hierarchy and hands it to `onResolve`. `onResolve`
/// can be called more than once — across a window close/reopen, or on a later
/// layout pass — so callers must treat it as idempotent.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // `view.window` is nil until the view joins the hierarchy; resolve on
        // the next runloop tick, once it has a window.
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { onResolve(window) }
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
        privacyViewModel: PrivacyViewModel.live(),
        appUninstallerViewModel: AppUninstallerViewModel.live(exclusions: exclusions),
        appUpdaterViewModel: AppUpdaterViewModel.live(),
        extensionsManagerViewModel: ExtensionsManagerViewModel.live(),
        optimizationViewModel: OptimizationViewModel.live(systemStats: stats, preferences: prefs),
        malwareViewModel: MalwareViewModel.live(
            dispatcher: notificationManager,
            preferences: prefs
        ),
        smartScanViewModel: SmartScanViewModel.live(exclusions: exclusions)
    )
        .environmentObject(AppState(checker: { true }))
        .environmentObject(PermissionOnboardingViewModel())
        .environmentObject(stats)
        .environmentObject(NotificationThresholdMonitor(
            stats: stats,
            preferences: prefs,
            dispatcher: notificationManager
        ))
}
