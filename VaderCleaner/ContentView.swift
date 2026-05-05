// ContentView.swift
// Root view — NavigationSplitView with sidebar listing all 11 sections and placeholder detail views.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var onboarding: PermissionOnboardingViewModel
    @EnvironmentObject private var systemStats: SystemStatsService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedSection: NavigationSection? = .smartScan

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
    }

    /// Routes the selected sidebar section to its detail view. Sections without
    /// a real implementation yet fall back to `PlaceholderDetailView`; Health
    /// Monitor (Prompt 9) is the first real wiring.
    @ViewBuilder
    private func detailView(for section: NavigationSection) -> some View {
        switch section {
        case .healthMonitor:
            HealthMonitorView(service: systemStats)
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
    ContentView()
        .environmentObject(AppState(checker: { true }))
        .environmentObject(PermissionOnboardingViewModel())
        .environmentObject(SystemStatsService(autostart: false))
}
