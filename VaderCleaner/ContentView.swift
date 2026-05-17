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
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $selectedSection) { section in
                // Icon-only rail: the name is carried by the hover tooltip and
                // the accessibility label, so selection and keyboard
                // navigation still work while the sidebar stays slim.
                Image(systemName: section.icon)
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .help(section.title)
                    .accessibilityLabel(section.title)
                    .accessibilityIdentifier(section.accessibilityIdentifier)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 56, ideal: 64, max: 72)
            // Let the branded gradient show through the sidebar so it reads as
            // a translucent panel rather than an opaque list.
            .scrollContentBackground(.hidden)
        } detail: {
            detailView(for: selectedSection ?? .smartScan)
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
