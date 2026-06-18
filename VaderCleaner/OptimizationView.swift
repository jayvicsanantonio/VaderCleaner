// OptimizationView.swift
// Optimization feature view — login items, launch agents (user/system), RAM flush, and system maintenance scripts.

import SwiftUI

/// Detail view shown when the user selects "Optimization" in the sidebar.
/// Four sections — Login Items, Launch Agents, RAM, Maintenance Scripts —
/// driven by `OptimizationViewModel`'s state machine.
struct OptimizationView: View {

    private var viewModel: OptimizationViewModel
    @Environment(\.openURL) private var openURL
    @State private var pendingRemoval: LaunchAgent?
    /// Toggles the ready surface between the recommendation dashboard and the
    /// full "View All Tasks" catalog.
    @State private var showAllTasks = false
    /// Which catalog pane to show. Owned here (not inside the catalog) so it
    /// survives the brief "Working…" remount and so a recommendation card can
    /// open the catalog on the matching pane — e.g. Review → Background Items.
    @State private var catalogPane: OptimizationTaskCatalogView.Pane = .maintenanceTasks
    /// Selected task ids for the catalog's multi-select Run. Owned here so the
    /// selection persists across the progress screen and a completed run.
    @State private var selectedTaskIDs: Set<String> = []

    init(viewModel: OptimizationViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.optimization.title)
            .task {
                if viewModel.phase == .idle {
                    await viewModel.refresh()
                }
            }
            .alert(
                String(
                    localized: "Remove this launch agent?",
                    comment: "Alert title asking the user to confirm removing a launch agent."
                ),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                )
            ) {
                Button(String(
                    localized: "Cancel",
                    comment: "Cancel button on the launch-agent removal confirmation alert."
                ), role: .cancel) {
                    pendingRemoval = nil
                }
                Button(String(
                    localized: "Remove",
                    comment: "Confirm-removal button on the launch-agent removal confirmation alert."
                ), role: .destructive) {
                    if let agent = pendingRemoval {
                        pendingRemoval = nil
                        Task { await viewModel.remove(agent) }
                    }
                }
            } message: {
                Text(removalConfirmationMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        // A multi-task batch flips each task's phase between .working and .ready;
        // keep the progress screen up for the whole batch so the view doesn't
        // flicker between progress and the catalog.
        if viewModel.isRunningBatch {
            OptimizationProgressState(label: workingLabel, identifier: "optimization.working")
        } else {
            phaseContent
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .idle:
            // Unreachable: ContentView shows the unified SectionIntroView
            // while the coordinator reports `.intro` (which `.idle` maps to),
            // so the detail view is never built in this phase. The arm stays
            // only to keep the switch exhaustive over `Phase`.
            EmptyView()
        case .loading:
            OptimizationProgressState(
                label: String(
                    localized: "Loading optimization data…",
                    comment: "Progress label while the Optimization view loads."
                ),
                identifier: "optimization.loading"
            )
        case .working:
            OptimizationProgressState(
                label: workingLabel,
                identifier: "optimization.working"
            )
        case .ready:
            readyContent
        case .failed(let message):
            OptimizationFailedState(
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
            comment: "Progress label while an Optimization action runs."
        )
    }

    @ViewBuilder
    private var readyContent: some View {
        if showAllTasks {
            // The catalog owns its full-height layout (sub-nav + scrolling pane
            // + pinned Run bar), so it replaces the dashboard entirely rather
            // than rendering inside it.
            OptimizationTaskCatalogView(
                pane: $catalogPane,
                selectedTaskIDs: $selectedTaskIDs,
                tasks: viewModel.tasks,
                results: viewModel.taskResults,
                loginItems: viewModel.loginItems,
                userAgents: viewModel.userAgents,
                systemAgents: viewModel.systemAgents,
                onRunSelected: { tasks in Task { await viewModel.run(tasks) } },
                onToggleLoginItem: { item, enabled in
                    Task { await viewModel.setLoginItem(item, enabled: enabled) }
                },
                onApproveLoginItem: { viewModel.openLoginItemsSettings() },
                onSetAgentEnabled: { agent, enabled in
                    Task {
                        if enabled {
                            await viewModel.enable(agent)
                        } else {
                            await viewModel.disable(agent)
                        }
                    }
                },
                onRemoveAgent: { pendingRemoval = $0 },
                onBack: { showAllTasks = false }
            )
        } else {
            OptimizationDashboardView(
                recommendations: viewModel.recommendations,
                completedKinds: viewModel.completedRecommendations,
                onAction: handleRecommendation,
                onViewAllTasks: {
                    catalogPane = .maintenanceTasks
                    showAllTasks = true
                },
                onRescan: { Task { await viewModel.refresh() } }
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Routes a recommendation card's primary action: the RAM, maintenance, and
    /// snapshot cards run their task directly; the background-items card opens
    /// the catalog where those items are managed.
    private func handleRecommendation(_ recommendation: PerformanceRecommendation) {
        switch recommendation.kind {
        case .backgroundItems:
            // Open the catalog directly on the Background Items pane, where
            // login items and launch agents are managed.
            catalogPane = .backgroundItems
            showAllTasks = true
        case .freeUpRAM, .maintenanceTasks, .thinSnapshots:
            // Runnable tiles route through the view model, which marks the tile
            // complete on success so it shows a green check.
            Task { await viewModel.runRecommendation(recommendation) }
        }
    }

    private var removalConfirmationMessage: String {
        if let agent = pendingRemoval {
            let format = String(
                localized: "%@ will be permanently deleted from disk. This cannot be undone.",
                comment: "Alert message confirming a launch-agent removal; %@ is the agent label."
            )
            return String.localizedStringWithFormat(format, agent.label)
        }
        return String(
            localized: "The selected launch agent will be permanently deleted from disk.",
            comment: "Fallback alert message confirming a launch-agent removal."
        )
    }
}

#Preview {
    OptimizationView(viewModel: OptimizationViewModel(
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
