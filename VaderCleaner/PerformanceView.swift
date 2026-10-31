// PerformanceView.swift
// Performance feature view — login items, launch agents (user/system), RAM flush, and system maintenance scripts.

import AppKit
import SwiftUI
import VaderCleanerCore

/// Detail view shown when the user selects "Performance" in the sidebar.
/// A dashboard and the Performance Manager behind it — Login Items, Background
/// Items, Maintenance Tasks — driven by `PerformanceViewModel`'s state machine.
struct PerformanceView: View {

    private var viewModel: PerformanceViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Toggles the ready surface between the summary dashboard and the full
    /// "View All Tasks" Performance Manager.
    @State private var showAllTasks = false
    /// Which catalog pane to show. Owned here (not inside the catalog) so a
    /// recommendation card can open the catalog on the matching pane — e.g.
    /// Review → Background Items.
    @State private var catalogPane: PerformanceTaskCatalogView.Pane = .maintenanceTasks
    /// Selected task ids for the catalog's multi-select Run. Owned here so the
    /// Maintenance card's Review can preselect what is due.
    @State private var selectedTaskIDs: Set<String> = []
    /// Where the manager zoom anchors: the button that opened it, resolved
    /// by `openCatalog`. Also the point Back zooms the manager back into.
    @State private var managerAnchor: UnitPoint = .center
    /// The transition host's frame in global space, for mapping the opening
    /// click to `managerAnchor`.
    @State private var paneFrame: CGRect = .zero
    /// The title-bar safe-area inset the transition host permanently claims;
    /// handed back to the dashboard as top padding so only the manager
    /// extends under the title bar.
    @State private var paneTopInset: CGFloat = 0

    init(viewModel: PerformanceViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.performance.title)
            // ContentView rebuilds this view each time the section is selected,
            // so this also catches what changed while the user was elsewhere —
            // an uninstalled app taking its agent with it, for one.
            .task {
                if viewModel.phase == .idle {
                    await viewModel.refresh()
                } else {
                    await viewModel.reloadInBackground()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await viewModel.reloadInBackground() }
            }
    }

    private var content: some View {
        ZStack {
            // Stays mounted under the progress and failure screens so an action
            // doesn't cost the manager its search, selection, and scroll
            // position. Hidden means disabled too, or Return would still reach
            // its footer button.
            if hasLoaded {
                readyContent
                    .opacity(showsReadyContent ? 1 : 0)
                    .disabled(!showsReadyContent)
                    .accessibilityHidden(!showsReadyContent)
            }
            statusContent
        }
    }

    /// Whether the lists have loaded, which is when the dashboard can exist.
    private var hasLoaded: Bool {
        switch viewModel.phase {
        case .ready, .working, .failed: return true
        case .idle, .loading: return false
        }
    }

    /// A multi-task batch flips each task's phase between .working and .ready, so
    /// `isRunningBatch` keeps the progress screen up for the whole batch.
    private var showsReadyContent: Bool {
        viewModel.phase == .ready && !viewModel.isRunningBatch
    }

    @ViewBuilder
    private var statusContent: some View {
        if viewModel.isRunningBatch {
            PerformanceProgressState(label: workingLabel, identifier: "performance.working")
        } else {
            phaseStatus
        }
    }

    @ViewBuilder
    private var phaseStatus: some View {
        switch viewModel.phase {
        case .idle, .ready:
            // `.idle` is unreachable: ContentView shows the unified
            // SectionIntroView while the coordinator reports `.intro` (which
            // `.idle` maps to), so the detail view is never built in this phase.
            EmptyView()
        case .loading:
            PerformanceProgressState(
                label: String(
                    localized: "Loading performance data…",
                    comment: "Progress label while the Performance view loads."
                ),
                identifier: "performance.loading"
            )
        case .working:
            PerformanceProgressState(
                label: workingLabel,
                identifier: "performance.working"
            )
        case .failed(let message):
            PerformanceFailedState(
                message: message,
                onDismiss: { viewModel.dismissResult() },
                onOpenFullDiskAccess: viewModel.failureNeedsFullDiskAccess
                    ? { openURL(PermissionOnboardingViewModel.systemSettingsURL) }
                    : nil
            )
        }
    }

    /// Names the running action on the progress screen, falling back to a
    /// generic label for loads that don't set a title.
    private var workingLabel: String {
        if let title = viewModel.workingTitle {
            return "\(title)…"
        }
        return String(
            localized: "Working…",
            comment: "Progress label while an Performance action runs."
        )
    }

    /// The dashboard and the task catalog exchange inside
    /// `ManagerPresentationHost` (a stable transition host) with the shared
    /// manager motion: the catalog zooms up from the button that opened it
    /// over the receding dashboard, and zooms back into it on Back — after
    /// which it stays mounted (hidden), so reopening restores it instantly.
    /// Deep links keep working while it's retained because the catalog reads
    /// its pane through the `$catalogPane` binding.
    private var readyContent: some View {
        ManagerPresentationHost(
            isPresented: showAllTasks,
            anchor: managerAnchor,
            reduceMotion: reduceMotion,
            dashboardTopInset: paneTopInset
        ) {
            PerformanceDashboardView(
                loginItemCount: viewModel.loginItems.count,
                loginItemBundleIDs: viewModel.loginItems.map(\.id),
                backgroundItemCount: viewModel.userAgents.count + viewModel.systemAgents.count,
                maintenanceTasksDue: viewModel.maintenanceTasksDue,
                accent: NavigationSection.performance.theme.accent,
                onViewAllTasks: { openCatalog(pane: .maintenanceTasks) },
                onReviewLoginItems: { openCatalog(pane: .loginItems) },
                onReviewBackgroundItems: { openCatalog(pane: .backgroundItems) },
                onReviewMaintenance: {
                    // The card's count leads somewhere: what is due is what's ticked.
                    selectedTaskIDs = viewModel.dueMaintenanceTaskIDs
                    openCatalog(pane: .maintenanceTasks)
                }
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } manager: {
            // The manager owns its full-height card layout (header + nav + pane +
            // footer), so it replaces the dashboard entirely rather than
            // rendering inside it.
            PerformanceTaskCatalogView(
                pane: $catalogPane,
                selectedTaskIDs: $selectedTaskIDs,
                tasks: viewModel.tasks,
                dueTaskIDs: viewModel.dueMaintenanceTaskIDs,
                results: viewModel.taskResults,
                loginItems: viewModel.loginItems,
                userAgents: viewModel.userAgents,
                systemAgents: viewModel.systemAgents,
                onRunSelected: { tasks in Task { await viewModel.run(tasks) } },
                onRemoveSelected: { loginIDs, agentIDs in
                    Task { await viewModel.removeSelected(loginItemIDs: loginIDs, agentIDs: agentIDs) }
                },
                onSetAgentEnabled: { agent, enabled in
                    Task {
                        if enabled {
                            await viewModel.enable(agent)
                        } else {
                            await viewModel.disable(agent)
                        }
                    }
                },
                onOpenLoginItemsSettings: { viewModel.openLoginItemsSettings() },
                onBack: { showAllTasks = false }
            )
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame = $0 })
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { paneTopInset = $0 })
    }

    /// Anchors the zoom to the button (or failing that, the click) being
    /// handled, then raises the catalog on `pane`.
    private func openCatalog(pane: PerformanceTaskCatalogView.Pane) {
        managerAnchor = TriggerAnchor.resolve(in: paneFrame)
        catalogPane = pane
        showAllTasks = true
        Task { await viewModel.reloadInBackground() }
    }
}

#Preview {
    PerformanceView(viewModel: PerformanceViewModel(
        loadLoginItems: {
            [LoginItem(id: "com.personal.VaderCleaner", name: "VaderCleaner", isEnabled: true)]
        },
        loadUserAgents: {
            [LaunchAgent(
                label: "com.acme.updater",
                path: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/com.acme.updater.plist"),
                programPath: "/Applications/Acme.app/Contents/Helpers/updater",
                isEnabled: true,
                domain: .user
            )]
        },
        loadSystemAgents: {
            [LaunchAgent(
                label: "com.vendor.daemon",
                path: URL(fileURLWithPath: "/Library/LaunchDaemons/com.vendor.daemon.plist"),
                programPath: "/usr/local/bin/vendord",
                isEnabled: false,
                domain: .system
            )]
        },
        readMemory: { MemoryStats(usedBytes: 12_000_000_000, totalBytes: 16_000_000_000) },
        setLoginItemEnabled: { _, _ in },
        disableAgent: { _ in },
        enableAgent: { _ in },
        removeAgent: { _ in },
        flushRAM: {},
        runMaintenance: { "Ran maintenance scripts." }
    ))
    .frame(width: 900, height: 600)
}
