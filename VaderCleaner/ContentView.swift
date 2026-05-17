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
    /// Latched once the notification permission prompt has been issued for the
    /// session. Without this, an `.onChange` flurry (FDA refresh tick + sheet
    /// dismissal in the same cycle) would request authorization twice — the
    /// system caches the answer so the second prompt is a no-op, but it's
    /// cleaner to issue exactly one.
    @State private var didRequestNotificationPermission = false
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

    var body: some View {
        HStack(spacing: 0) {
            // A custom rail of buttons (not a List) so selection can be a soft
            // inset glass pill with generous spacing instead of the system's
            // full-bleed selection bar. The rail and detail share one
            // continuous gradient — no sidebar material, no divider.
            rail
                .frame(width: 240)

            // Hosts `.navigationTitle` / `.toolbar` for the detail screens
            // without reintroducing a split divider.
            NavigationStack {
                detailView(for: selectedSection ?? .smartScan)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        // Branded shell: gradient backdrop, crimson tint, forced dark
        // appearance. The toolbar background is hidden so the floating glass
        // toolbar items sit directly over the gradient instead of on a band.
        .vaderShell()
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
        VStack(spacing: 4) {
            ForEach(NavigationSection.allCases) { section in
                railRow(section)
            }
        }
        .padding(.horizontal, 10)
        // The content extends under the hidden title bar, so inset the
        // first row clear of the window's traffic-light controls.
        .padding(.top, 44)
        .padding(.bottom, 16)
        // Fill the column and top-align. All eleven rows fit within the
        // window's minimum height, so the rail is intentionally not wrapped
        // in a ScrollView — it never scrolls.
        .frame(maxHeight: .infinity, alignment: .top)
        // Anchor the rail to the true window top. Detail screens declare
        // different toolbars, which changes the window's top safe-area inset;
        // without this the rail would ride that inset and shift vertically
        // between sections. The `.padding(.top, 44)` above clears the
        // traffic-light controls measured from this fixed top.
        .ignoresSafeArea(.container, edges: .top)
    }

    private func railRow(_ section: NavigationSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 14) {
                Image(systemName: section.icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    .frame(width: 26)
                Text(section.title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.62))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                if isSelected {
                    Color.clear
                        .glassEffect(
                            .regular.tint(Color.vaderCrimson),
                            in: .rect(cornerRadius: 12)
                        )
                        .matchedGeometryEffect(id: "selectionPill", in: pillNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Suppress the macOS keyboard focus ring. Without this the first
        // focusable row wears the system's blue halo on launch; the crimson
        // selection pill is the rail's own state indicator.
        .focusEffectDisabled()
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
            SmartScanView(
                viewModel: smartScanViewModel,
                onReviewSystemJunk: { selectedSection = .systemJunk },
                onReviewMalware: { selectedSection = .malwareRemoval },
                onReviewOptimization: { selectedSection = .optimization }
            )
        case .healthMonitor:
            HealthMonitorView(service: systemStats)
        case .systemJunk:
            SystemJunkView(viewModel: systemJunkViewModel)
        case .largeOldFiles:
            LargeOldFilesView(viewModel: largeOldFilesViewModel)
        case .spaceLens:
            SpaceLensView(viewModel: spaceLensViewModel)
        case .privacy:
            PrivacyView(viewModel: privacyViewModel)
        case .appUninstaller:
            AppUninstallerView(viewModel: appUninstallerViewModel)
        case .appUpdater:
            AppUpdaterView(viewModel: appUpdaterViewModel)
        case .extensions:
            ExtensionsManagerView(viewModel: extensionsManagerViewModel)
        case .optimization:
            OptimizationView(viewModel: optimizationViewModel)
        case .malwareRemoval:
            MalwareView(viewModel: malwareViewModel)
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
