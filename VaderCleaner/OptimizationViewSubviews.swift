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
    /// Optional one-line note under the title. Used to state a fact shared by
    /// every row once — e.g. "Managed by macOS" for the system-agents group —
    /// instead of repeating it down the column.
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
    let onApprove: () -> Void

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
                            // launchd holds the registration but it isn't active
                            // until the user approves it in System Settings —
                            // macOS grants that approval nowhere else. The
                            // caption explains the state and the link deep-links
                            // to the Login Items pane so it's one click. The
                            // wording reads correctly whether this is a brand-new
                            // registration awaiting first approval or one the
                            // user switched off there.
                            if item.requiresApproval {
                                HStack(spacing: 6) {
                                    Text(String(
                                        localized: "Pending — not active until approved",
                                        comment: "Hint shown when the app is registered for launch at login but the user must still approve it in System Settings."
                                    ))
                                    .foregroundStyle(.orange)
                                    Button(action: onApprove) {
                                        Text(String(
                                            localized: "Approve in Settings →",
                                            comment: "Link that opens System Settings to the Login Items pane so the user can approve the pending registration."
                                        ))
                                    }
                                    .buttonStyle(.link)
                                    .accessibilityIdentifier("optimization.loginItem.\(item.id).approve")
                                }
                                .font(.caption2)
                            }
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
    /// Optional note shown once under the header — e.g. the system group is
    /// entirely "Managed by macOS", so the rows no longer repeat that label.
    var subtitle: String? = nil
    let identifier: String
    let agents: [LaunchAgent]
    let onSetEnabled: (LaunchAgent, Bool) -> Void
    let onRemove: (LaunchAgent) -> Void

    var body: some View {
        OptimizationSection(title: title, subtitle: subtitle) {
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
                    // A stub plist with no runnable job can never load, so it
                    // carries no toggle — only Remove. The status sits as a
                    // compact badge by the name (rather than a repeated
                    // right-column label); tapping it explains the term, since
                    // hover tooltips don't fire reliably in this window.
                    if agent.isOrphaned && agent.domain == .user {
                        OptimizationOrphanedBadge(
                            accessibilityIdentifier: "\(identifier).orphaned.\(agent.path.lastPathComponent)"
                        )
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
            // can break macOS or the app that installed it. They carry no
            // per-row control — the section's "Managed by macOS" note states
            // that once for the whole group. User agents get the controls.
            if agent.domain != .system {
                if !agent.isOrphaned {
                    // The toggle is the agent's loaded state: on loads it via
                    // `launchctl load -w`, off unloads it via `unload -w`. Unlike
                    // a one-way "Disable" button it never greys into a dead
                    // control — a not-loaded agent simply shows the switch in its
                    // off position, which the user can flip back on. Orphaned
                    // plists can never load, so they show only Remove.
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

/// A compact "Orphaned" badge placed next to a launch agent's name. It reads as
/// a status pill but is tappable: clicking reveals what "orphaned" means in a
/// popover, since hover tooltips don't fire reliably in this window. Built from
/// an `HStack(Image, Text)` rather than a `Label` so the button still surfaces
/// to UI tests.
struct OptimizationOrphanedBadge: View {
    let accessibilityIdentifier: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "info.circle")
                    .imageScale(.small)
                Text(String(
                    localized: "Orphaned",
                    comment: "Badge for a launch-agent plist that defines no runnable job and can only be removed."
                ))
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(String(
                localized: "“Orphaned” means this is an empty leftover file with no app or program to start, so there's nothing to turn on. It's safe to remove, though the app that left it behind may add it back later.",
                comment: "Popover explaining what an orphaned launch agent is and why it shows no toggle."
            ))
            .font(.callout)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(width: 300)
        }
    }
}
