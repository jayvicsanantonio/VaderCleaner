// ContentView.swift
// Root view — NavigationSplitView with sidebar listing all 11 sections and placeholder detail views.

import SwiftUI

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
    /// the floating Scan overlay so the disc centers over the detail content
    /// area (not the full window) without the two drifting apart.
    private let railWidth: CGFloat = 240
    /// Bottom inset for the floating Scan overlay. Sized so the 108pt disc
    /// and its breathing glow sit fully inside the window above the bottom
    /// edge instead of being clipped by it.
    private let floatingScanBottomPadding: CGFloat = 32
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
                detailView(for: selectedSection ?? .smartScan)
                    // Crossfade the whole detail screen as the section
                    // changes, so navigation reads as a soft dissolve in step
                    // with the backdrop recolour rather than a hard cut.
                    .id(selectedSection)
                    .transition(.opacity)
            }
        }
        // The Scan CTA floats over the window's bottom edge. It is attached to
        // the OUTER HStack — outside the NavigationStack — so the detail
        // screens' toolbars and safe-area insets can't clip it. The leading
        // inset equal to the rail width re-centers the disc over the detail
        // content area rather than the full window, and the bottom padding
        // keeps the whole disc and its glow inside the window above the
        // bottom edge.
        .overlay(alignment: .bottom) {
            floatingScan(for: selectedSection ?? .smartScan)
                .padding(.leading, railWidth)
                .padding(.bottom, floatingScanBottomPadding)
        }
        // One ambient animation drives every section-change motion in lock
        // step: the rail's selection pill slides, the detail screen
        // crossfades, and the floating Scan disc recolours.
        .animation(.smooth(duration: 0.42), value: selectedSection)
        .frame(minWidth: 900, minHeight: 600)
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
            selectedSection = section
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
                    onReviewSystemJunk: { selectedSection = .systemJunk },
                    onReviewMalware: { selectedSection = .malwareRemoval },
                    onReviewOptimization: { selectedSection = .optimization }
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

    /// The shell-level floating Scan button for the selected section. Renders
    /// only for scannable sections and — via `FloatingScanOverlay`'s
    /// observation of the coordinator — only while that section is at its
    /// `.intro` phase; everything else collapses to nothing so the disc
    /// disappears the instant a scan starts. The switch is exhaustive so a new
    /// section is a compile-time prompt to classify it here.
    @ViewBuilder
    private func floatingScan(for section: NavigationSection) -> some View {
        switch section {
        case .smartScan:
            FloatingScanOverlay(coordinator: smartScanViewModel, section: section)
        case .systemJunk:
            FloatingScanOverlay(coordinator: systemJunkViewModel, section: section)
        case .largeOldFiles:
            FloatingScanOverlay(coordinator: largeOldFilesViewModel, section: section)
        case .spaceLens:
            FloatingScanOverlay(coordinator: spaceLensViewModel, section: section)
        case .optimization:
            FloatingScanOverlay(coordinator: optimizationViewModel, section: section)
        case .malwareRemoval:
            FloatingScanOverlay(coordinator: malwareViewModel, section: section)
        case .privacy:
            FloatingScanOverlay(coordinator: privacyViewModel, section: section)
        case .extensions, .appUninstaller, .appUpdater, .healthMonitor:
            EmptyView()
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
        content
            // Reuse SmartScanView's phase-transition pattern so the
            // intro → scan swap crossfades instead of hard-cutting.
            .id(phaseTransitionID)
            .transition(.opacity)
            .animation(.smooth(duration: 0.35), value: phaseTransitionID)
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

/// The shell-level floating Scan button for one scannable section. Observes
/// the coordinator so the disc is shown only while the section is at `.intro`
/// and vanishes the moment a scan starts. Accent-tinted per section; the
/// window's crimson shell is unchanged.
private struct FloatingScanOverlay<Coordinator: ScanCoordinating>: View {
    @ObservedObject var coordinator: Coordinator
    let section: NavigationSection

    var body: some View {
        Group {
            if coordinator.scanPresentation == .intro {
                FloatingScanButton(
                    title: String(localized: "Scan", comment: "Floating scan button title."),
                    accent: SectionPresentation.for(section)?.accent ?? .vaderCrimson,
                    accessibilityIdentifier: section.scanAccessibilityIdentifier,
                    accessibilityLabel: String(
                        localized: "Scan \(section.title)",
                        comment: "VoiceOver label for a section's floating scan button, e.g. \"Scan System Junk\"."
                    ),
                    action: { coordinator.beginScan() }
                )
                .transition(.opacity)
            }
        }
        // The disc fades out as the section leaves `.intro` instead of
        // popping, staying in lock-step with the intro → detail crossfade
        // `ScannableSectionContent` runs on the same value.
        .animation(.smooth(duration: 0.35), value: coordinator.scanPresentation)
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
