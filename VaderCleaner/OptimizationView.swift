// OptimizationView.swift
// Optimization feature view — login items, launch agents (user/system), RAM flush, and system maintenance scripts.

import SwiftUI

/// Detail view shown when the user selects "Optimization" in the sidebar.
/// Four sections — Login Items, Launch Agents, RAM, Maintenance Scripts —
/// driven by `OptimizationViewModel`'s state machine.
struct OptimizationView: View {

    private var viewModel: OptimizationViewModel
    @State private var pendingRemoval: LaunchAgent?

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
                label: String(
                    localized: "Working…",
                    comment: "Progress label while an Optimization action runs."
                ),
                identifier: "optimization.working"
            )
        case .ready:
            sections
        case .failed(let message):
            OptimizationFailedState(message: message) {
                viewModel.dismissResult()
            }
        }
    }

    private var sections: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    OptimizationLoginItemsSection(
                        items: viewModel.loginItems,
                        onToggle: { item, enabled in
                            Task { await viewModel.setLoginItem(item, enabled: enabled) }
                        }
                    )
                    OptimizationLaunchAgentsSection(
                        title: String(
                            localized: "Launch Agents (User)",
                            comment: "Section header for user launch agents."
                        ),
                        identifier: "optimization.userAgents",
                        agents: viewModel.userAgents,
                        onDisable: { agent in Task { await viewModel.disable(agent) } },
                        onRemove: { pendingRemoval = $0 }
                    )
                    OptimizationLaunchAgentsSection(
                        title: String(
                            localized: "Launch Agents & Daemons (System)",
                            comment: "Section header for system launch agents and daemons."
                        ),
                        identifier: "optimization.systemAgents",
                        agents: viewModel.systemAgents,
                        onDisable: { agent in Task { await viewModel.disable(agent) } },
                        onRemove: { pendingRemoval = $0 }
                    )
                    OptimizationRAMSection(
                        memory: viewModel.memory,
                        result: viewModel.ramResult,
                        onFlush: { Task { await viewModel.flushRAM() } }
                    )
                    OptimizationMaintenanceSection(
                        output: viewModel.maintenanceOutput,
                        onRun: { Task { await viewModel.runMaintenanceScripts() } }
                    )
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button(String(
                    localized: "Refresh",
                    comment: "Footer button that reloads Optimization data."
                )) {
                    Task { await viewModel.refresh() }
                }
                .accessibilityIdentifier("optimization.refresh")
            }
            .padding(16)
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
        removeAgent: { _ in },
        flushRAM: {},
        runMaintenance: { "Ran maintenance scripts." }
    ))
    .frame(width: 900, height: 600)
}
