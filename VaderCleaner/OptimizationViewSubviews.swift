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
                        identifier: identifier,
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
    let identifier: String
    let onDisable: () -> Void
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
                    if !agent.isEnabled && agent.domain == .user {
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
            Button(action: onDisable) {
                Text(String(
                    localized: "Disable",
                    comment: "Per-row button that unloads a launch agent via launchctl."
                ))
            }
            .buttonStyle(.bordered)
            // System daemons live in launchd's privileged domain; `launchctl
            // unload` from the user session can't touch them, so the control
            // is offered only for user agents.
            .disabled(!agent.isEnabled || agent.domain == .system)
            .help(agent.domain == .system
                  ? String(
                        localized: "System daemons are managed by macOS or the app that installed them and can't be changed here.",
                        comment: "Tooltip explaining why a system launch daemon can't be disabled or removed."
                    )
                  : "")
            .accessibilityIdentifier("\(identifier).disable.\(agent.path.lastPathComponent)")

            Button(role: .destructive, action: onRemove) {
                Text(String(
                    localized: "Remove",
                    comment: "Per-row button that deletes a launch-agent plist."
                ))
            }
            .buttonStyle(.bordered)
            // System daemons are protected from removal — deleting one can break
            // macOS or the app that installed it. Only user agents can be removed.
            .disabled(agent.domain == .system)
            .help(agent.domain == .system
                  ? String(
                        localized: "Protected: system daemons can't be removed here. Disable it in System Settings or its app instead.",
                        comment: "Tooltip explaining why a system launch daemon can't be removed."
                    )
                  : "")
            .accessibilityIdentifier("\(identifier).remove.\(agent.path.lastPathComponent)")
        }
        .padding(.vertical, 4)
    }
}
