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
        extensionsManagerViewModel: ExtensionsManagerViewModel
    ) {
        self.systemJunkViewModel = systemJunkViewModel
        self.largeOldFilesViewModel = largeOldFilesViewModel
        self.spaceLensViewModel = spaceLensViewModel
        self.privacyViewModel = privacyViewModel
        self.appUninstallerViewModel = appUninstallerViewModel
        self.appUpdaterViewModel = appUpdaterViewModel
        self.extensionsManagerViewModel = extensionsManagerViewModel
    }

    var body: some View {
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detailView(for: selectedSection ?? .smartScan)
        }
        .frame(minWidth: 900, minHeight: 600)
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

    /// Routes the selected sidebar section to its detail view. Sections without
    /// a real implementation yet fall back to `PlaceholderDetailView`; Health
    /// Monitor (Prompt 9) is the first real wiring.
    @ViewBuilder
    private func detailView(for section: NavigationSection) -> some View {
        switch section {
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
        default:
            PlaceholderDetailView(section: section)
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

private struct PlaceholderDetailView: View {
    let section: NavigationSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)
            Text("Coming Soon")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(section.title)
    }
}

#Preview {
    let stats = SystemStatsService(autostart: false)
    let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "preview")!)
    let exclusions = ExclusionsStore(defaults: UserDefaults(suiteName: "preview")!)
    return ContentView(
        systemJunkViewModel: SystemJunkViewModel.live(exclusions: exclusions),
        largeOldFilesViewModel: LargeOldFilesViewModel.live(exclusions: exclusions),
        spaceLensViewModel: DiskScannerViewModel.live(),
        privacyViewModel: PrivacyViewModel.live(),
        appUninstallerViewModel: AppUninstallerViewModel.live(),
        appUpdaterViewModel: AppUpdaterViewModel.live(),
        extensionsManagerViewModel: ExtensionsManagerViewModel.live()
    )
        .environmentObject(AppState(checker: { true }))
        .environmentObject(PermissionOnboardingViewModel())
        .environmentObject(stats)
        .environmentObject(NotificationThresholdMonitor(
            stats: stats,
            preferences: prefs,
            dispatcher: NotificationManager()
        ))
}
