// OptimizationViewSubviews.swift
// Dedicated subviews for the Optimization screen — login items, launch-agent groups, RAM, maintenance, and progress / failed states.

import SwiftUI

// MARK: - Progress / failed states

struct OptimizationProgressState: View {
    let label: String
    let identifier: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

struct OptimizationFailedState: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(String(
                localized: "That action couldn't complete",
                comment: "Heading on the Optimization failure screen."
            ))
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("optimization.errorMessage")
            Button(String(
                localized: "Back to Optimization",
                comment: "Return button on the Optimization failure screen."
            ), action: onDismiss)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("optimization.failurePrimary")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Section chrome

private struct OptimizationSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            content
        }
    }
}

private struct OptimizationEmptyRow: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}

// MARK: - Login items

struct OptimizationLoginItemsSection: View {
    let items: [LoginItem]
    let onToggle: (LoginItem, Bool) -> Void

    var body: some View {
        OptimizationSection(title: String(
            localized: "Login Items",
            comment: "Optimization section header for login items."
        )) {
            if items.isEmpty {
                OptimizationEmptyRow(message: String(
                    localized: "No manageable login items.",
                    comment: "Empty state for the Login Items section."
                ))
            } else {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.body)
                            Text(item.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { item.isEnabled },
                            set: { onToggle(item, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("optimization.loginItem.\(item.id)")
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }
}

// MARK: - Launch agents

struct OptimizationLaunchAgentsSection: View {
    let title: String
    let identifier: String
    let agents: [LaunchAgent]
    let onDisable: (LaunchAgent) -> Void
    let onRemove: (LaunchAgent) -> Void

    var body: some View {
        OptimizationSection(title: title) {
            if agents.isEmpty {
                OptimizationEmptyRow(message: String(
                    localized: "Nothing found here.",
                    comment: "Empty state for a launch-agents section."
                ))
                .accessibilityIdentifier("\(identifier).empty")
            } else {
                ForEach(agents) { agent in
                    OptimizationLaunchAgentRow(
                        agent: agent,
                        onDisable: { onDisable(agent) },
                        onRemove: { onRemove(agent) }
                    )
                    .accessibilityIdentifier("\(identifier).row.\(agent.path.lastPathComponent)")
                    Divider()
                }
            }
        }
    }
}

struct OptimizationLaunchAgentRow: View {
    let agent: LaunchAgent
    let onDisable: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.label)
                        .font(.body)
                        .lineLimit(1)
                    if !agent.isEnabled {
                        Text(String(
                            localized: "Not loaded",
                            comment: "Badge shown next to a launch agent that launchctl does not list as loaded."
                        ))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(Capsule())
                    }
                }
                Text(agent.programPath ?? agent.path.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onDisable) {
                Text(String(
                    localized: "Disable",
                    comment: "Per-row button that unloads a launch agent via launchctl."
                ))
            }
            .buttonStyle(.bordered)
            // System daemons live in launchd's privileged domain; `launchctl
            // unload` from the user session can't touch them, so the control
            // is offered only for user agents. Removal still works for system
            // agents (it routes through the privileged helper).
            .disabled(!agent.isEnabled || agent.domain == .system)
            .help(agent.domain == .system
                  ? String(
                        localized: "System agents can't be unloaded from here. Use Remove to delete the plist.",
                        comment: "Tooltip explaining why Disable is unavailable for system launch agents."
                    )
                  : "")
            .accessibilityIdentifier("optimization.disable.\(agent.path.lastPathComponent)")

            Button(role: .destructive, action: onRemove) {
                Text(String(
                    localized: "Remove",
                    comment: "Per-row button that deletes a launch-agent plist."
                ))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("optimization.remove.\(agent.path.lastPathComponent)")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - RAM

struct OptimizationRAMSection: View {
    let memory: MemoryStats
    let result: String?
    let onFlush: () -> Void

    var body: some View {
        OptimizationSection(title: String(
            localized: "RAM",
            comment: "Optimization section header for memory."
        )) {
            HStack {
                Text(SystemStatsFormatters.memoryUsageString(memory))
                    .font(.body.monospacedDigit())
                    .accessibilityIdentifier("optimization.ramUsage")
                Spacer()
                Button(action: onFlush) {
                    Text(String(
                        localized: "Free Up RAM",
                        comment: "Button that flushes inactive memory."
                    ))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("optimization.freeRAM")
            }
            if let result {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("optimization.ramResult")
            }
        }
    }
}

// MARK: - Maintenance

struct OptimizationMaintenanceSection: View {
    let output: String?
    let onRun: () -> Void

    var body: some View {
        OptimizationSection(title: String(
            localized: "Maintenance Scripts",
            comment: "Optimization section header for maintenance scripts."
        )) {
            HStack {
                Text(String(
                    localized: "Runs the system periodic daily, weekly, and monthly scripts.",
                    comment: "Explanatory text for the maintenance scripts action."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: onRun) {
                    Text(String(
                        localized: "Run Maintenance Scripts",
                        comment: "Button that runs the system maintenance scripts."
                    ))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("optimization.runMaintenance")
            }
            if let output {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("optimization.maintenanceOutput")
            }
        }
    }
}
