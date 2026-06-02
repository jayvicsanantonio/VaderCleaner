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
    /// When set, the failure is recoverable by granting Full Disk Access — the
    /// screen offers a button that jumps straight to that Settings pane.
    var onOpenFullDiskAccess: (() -> Void)? = nil

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
            if let onOpenFullDiskAccess {
                Button(String(
                    localized: "Open Full Disk Access Settings",
                    comment: "Recovery button that opens the Full Disk Access settings pane."
                ), action: onOpenFullDiskAccess)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("optimization.failureOpenFullDiskAccess")
            }
            Button(String(
                localized: "Back to Optimization",
                comment: "Return button on the Optimization failure screen."
            ), action: onDismiss)
                .controlSize(.large)
                .keyboardShortcut(onOpenFullDiskAccess == nil ? .defaultAction : nil)
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
    let onSetEnabled: (LaunchAgent, Bool) -> Void
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
                        identifier: identifier,
                        onSetEnabled: { onSetEnabled(agent, $0) },
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
    let identifier: String
    let onSetEnabled: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.label)
                        .font(.body)
                        .lineLimit(1)
                    // `launchctl list` runs in the user bootstrap and cannot
                    // see system daemons, so a "Not loaded" badge there would
                    // be a false negative. Only user agents have an
                    // authoritative loaded status to badge.
                    if !agent.isEnabled && agent.domain == .user && !agent.isOrphaned {
                        Text(String(
                            localized: "Not loaded",
                            comment: "Badge shown next to a user launch agent that launchctl does not list as loaded."
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
            // System daemons live in launchd's privileged domain: `launchctl
            // unload` from the user session can't touch them and deleting one
            // can break macOS or the app that installed it. Rather than offer
            // dead controls, surface a read-only "Managed by macOS" indicator.
            if agent.domain == .system {
                Label(
                    String(
                        localized: "Managed by macOS",
                        comment: "Read-only indicator shown for system launch agents and daemons that can't be changed in the app."
                    ),
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .help(String(
                    localized: "This item is controlled by macOS or the app that installed it, so it can't be turned off or removed here. To change it, use System Settings or that app's own settings.",
                    comment: "Tooltip explaining why a system launch daemon can't be disabled or removed."
                ))
                .accessibilityIdentifier("\(identifier).managed.\(agent.path.lastPathComponent)")
            } else {
                if agent.isOrphaned {
                    // A stub plist with no runnable job can never be loaded, so a
                    // toggle would only ever bounce back to off. Mark it as a
                    // leftover file the user can remove instead.
                    Label(
                        String(
                            localized: "Orphaned",
                            comment: "Indicator for a launch-agent plist that defines no runnable job and can only be removed."
                        ),
                        systemImage: "questionmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help(String(
                        localized: "“Orphaned” means this is an empty leftover file with no app or program to start, so there's nothing to turn on. It's safe to remove, though the app that left it behind may add it back later.",
                        comment: "Tooltip explaining what an orphaned launch agent is and why it shows no toggle."
                    ))
                    .accessibilityIdentifier("\(identifier).orphaned.\(agent.path.lastPathComponent)")
                } else {
                    // The toggle is the agent's loaded state: on loads it via
                    // `launchctl load -w`, off unloads it via `unload -w`. Unlike
                    // a one-way "Disable" button it never greys into a dead
                    // control — a not-loaded agent simply shows the switch in its
                    // off position, which the user can flip back on.
                    Toggle("", isOn: Binding(
                        get: { agent.isEnabled },
                        set: { onSetEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(agent.isEnabled
                          ? String(
                                localized: "Loaded. Turn off to unload this agent and keep it off across logins.",
                                comment: "Tooltip for an enabled user launch-agent toggle."
                            )
                          : String(
                                localized: "Not loaded. Turn on to load this agent and keep it on across logins.",
                                comment: "Tooltip for a disabled user launch-agent toggle."
                            ))
                    .accessibilityIdentifier("\(identifier).toggle.\(agent.path.lastPathComponent)")
                }

                Button(role: .destructive, action: onRemove) {
                    Text(String(
                        localized: "Remove",
                        comment: "Per-row button that deletes a launch-agent plist."
                    ))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(identifier).remove.\(agent.path.lastPathComponent)")
            }
        }
        .padding(.vertical, 4)
    }
}
