// ContentView.swift
// Root view — NavigationSplitView with sidebar listing all 11 sections and placeholder detail views.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var onboarding: PermissionOnboardingViewModel
    @EnvironmentObject private var systemStats: SystemStatsService
    @EnvironmentObject private var notificationMonitor: NotificationThresholdMonitor
    @EnvironmentObject private var exclusions: ExclusionsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSection: NavigationSection? = .smartScan
    /// Latched once the notification permission prompt has been issued for the
    /// session. Without this, an `.onChange` flurry (FDA refresh tick + sheet
    /// dismissal in the same cycle) would request authorization twice — the
    /// system caches the answer so the second prompt is a no-op, but it's
    /// cleaner to issue exactly one.
    @State private var didRequestNotificationPermission = false
    /// Space Lens scans take long enough that losing the result on a
    /// sidebar peek would be a frustration point. Hosting the view-model
    /// here keeps the breadcrumb / scanned tree alive while the user
    /// flips through other sections, and only the view layer is rebuilt
    /// when they come back. A short-lived `SpaceLensView`-owned
    /// `@StateObject` would still latch the first scan via SwiftUI's
    /// state-object identity rules, but the VM would briefly construct
    /// (and a `.live()`-spawned `DiskScanner` would briefly allocate) on
    /// every body recomputation — wasteful enough to lift here.
    @StateObject private var spaceLensViewModel = DiskScannerViewModel.live()

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
            SystemJunkView(viewModel: SystemJunkViewModel.live(exclusions: exclusions))
        case .largeOldFiles:
            LargeOldFilesView(viewModel: LargeOldFilesViewModel.live(exclusions: exclusions))
        case .spaceLens:
            SpaceLensView(viewModel: spaceLensViewModel)
        case .privacy:
            PrivacyView(viewModel: PrivacyViewModel.live())
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
    return ContentView()
        .environmentObject(AppState(checker: { true }))
        .environmentObject(PermissionOnboardingViewModel())
        .environmentObject(stats)
        .environmentObject(NotificationThresholdMonitor(
            stats: stats,
            preferences: prefs,
            dispatcher: NotificationManager()
        ))
        .environmentObject(ExclusionsStore(defaults: UserDefaults(suiteName: "preview")!))
}
