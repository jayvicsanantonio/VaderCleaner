// PerformanceManagerRows.swift
// The rows of the Performance Manager's lists — maintenance tasks with their due and done marks, login and background items with their controls — and the icon badge they share.

import AppKit
import SwiftUI
import VaderCleanerCore

/// One selectable maintenance task — a checkbox, a colourful icon badge, the
/// task name, a "Due" mark when it is due to run again, an info button explaining
/// what it does, and (after running) the most recent result line.
struct PerformanceTaskRow: View {
    let task: MaintenanceTask
    let tint: Color
    let isSelected: Bool
    let isDue: Bool
    let result: String?
    let onToggle: () -> Void

    private var isCompleted: Bool { result != nil }

    /// Always-present secondary line: the task summary normally, the result once
    /// it has run. Kept to one line so the row height never changes.
    private var subtitle: String { result ?? task.summary }

    var body: some View {
        HStack(spacing: 12) {
            ManagerRowCheckbox(isOn: isSelected, action: onToggle)
                .accessibilityIdentifier("performance.task.checkbox.\(task.kind.rawValue)")

            TaskIconBadge(symbol: task.icon, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                    // Clear success indicator once the task has run.
                    if isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                            .accessibilityIdentifier("performance.task.done.\(task.kind.rawValue)")
                    } else if isDue {
                        Text(String(localized: "Due", comment: "Marks a maintenance task that is due to run again."))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .accessibilityIdentifier("performance.task.due.\(task.kind.rawValue)")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isCompleted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The full result/summary is available on hover; the row
                    // stays one line so its height is stable.
                    .help(subtitle)
            }

            Spacer()

            SmartInsightsSparkle(itemTitle: task.title, topic: .maintenanceTask)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("performance.task.\(task.kind.rawValue)")
        .animation(.smooth(duration: 0.25), value: isCompleted)
    }
}

/// One Login Items / Background Items card, matching the Maintenance Tasks row
/// styling: a checkbox (absent on a locked row, which is listed for review only),
/// the item's icon (the real Finder icon when it has one, else a tinted badge),
/// the name with a one-line detail underneath, any control the item offers, and
/// the trailing pink sparkle.
struct PerformanceItemRow: View {

    /// What the row offers beyond its checkbox.
    enum Control {
        case none
        /// Turns the item on or off without removing it.
        case toggle(isOn: Bool, identifier: String, action: @MainActor (Bool) -> Void)
        /// Sends the user to the only place macOS grants a pending approval.
        case openSettings(action: () -> Void)
    }

    let item: ManagerItem
    let isSelected: Bool
    let identifier: String
    let control: Control
    let onToggle: () -> Void

    // Resolved once per icon path rather than on every render: the Finder-icon
    // lookup is a synchronous NSWorkspace call, and a checkbox toggle re-renders
    // every row in the pane.
    @State private var fileIcon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            if !item.isLocked {
                ManagerRowCheckbox(isOn: isSelected, action: onToggle)
            }

            iconView

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The full detail (often a long path) stays readable on
                        // hover; the row stays one line so its height is stable.
                        .help(subtitle)
                }
            }

            Spacer()

            controlView

            SmartInsightsSparkle(itemTitle: item.title, topic: .loginItem)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !item.isLocked { onToggle() } }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier(identifier)
        .task(id: item.iconPath ?? item.id) { resolveFileIcon() }
    }

    @ViewBuilder
    private var controlView: some View {
        switch control {
        case .none:
            EmptyView()
        case .toggle(let isOn, let identifier, let action):
            Toggle(
                String(localized: "Run in Background", comment: "Accessibility label of the switch that turns a background item on or off."),
                isOn: Binding(get: { isOn }, set: { action($0) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier(identifier)
        case .openSettings(let action):
            Button(String(localized: "Approve in System Settings", comment: "Opens System Settings for a login item awaiting approval."), action: action)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if item.usesFileIcon, let fileIcon {
            Image(nsImage: fileIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
        } else {
            TaskIconBadge(symbol: item.systemImage, tint: item.tint.color)
        }
    }

    private func resolveFileIcon() {
        guard item.usesFileIcon else { return }
        fileIcon = NSWorkspace.shared.icon(forFile: item.iconPath ?? item.id)
    }
}

/// A colourful rounded-square icon badge — the SF Symbol on a per-task tinted
/// gradient, giving each task a distinct, app-like glyph.
struct TaskIconBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        let fill = tint.deepenedForWhite
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(
                LinearGradient(
                    colors: [fill.opacity(0.95), fill.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: .rect(cornerRadius: 10)
            )
    }
}

/// Per-task accent colours for the icon badges. Kept in the view layer so the
/// `MaintenanceTask` model stays free of UI types.
enum PerformanceTaskPalette {
    static func tint(for kind: MaintenanceTask.Kind) -> Color {
        switch kind {
        case .freeUpRAM:
            return Color(red: 0.95, green: 0.45, blue: 0.20)
        case .runMaintenanceScripts:
            return Color(red: 0.55, green: 0.45, blue: 0.95)
        case .flushDNS:
            return Color(red: 0.96, green: 0.62, blue: 0.24)
        case .reindexSpotlight:
            return Color(red: 0.95, green: 0.76, blue: 0.20)
        case .thinTimeMachineSnapshots:
            return Color(red: 0.96, green: 0.55, blue: 0.30)
        case .speedUpMail:
            return Color(red: 0.36, green: 0.62, blue: 0.96)
        }
    }
}
