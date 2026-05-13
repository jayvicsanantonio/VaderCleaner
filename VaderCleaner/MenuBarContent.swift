// MenuBarContent.swift
// SwiftUI view rendering the menu bar extra popover — RAM/Disk/CPU/Battery rows + Open and Quit actions.

import SwiftUI
import AppKit

/// Popover content presented when the user clicks the menu bar icon. Rows are
/// driven by `MenuBarViewModel` which is in turn fed by `SystemStatsService`,
/// so values refresh on the same 2-second cadence as the Health Monitor.
///
/// The Battery row is conditional — desktops report no internal battery and
/// startup begins with unknown battery state, so rendering an empty row would
/// just look like a UI bug.
struct MenuBarContent: View {

    @EnvironmentObject private var menuBar: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ramRow
            statRow(label: "Disk", value: menuBar.formattedDiskSpace)
            statRow(label: "CPU", value: menuBar.formattedCPU)
            if let battery = menuBar.formattedBatteryHealth {
                statRow(label: "Battery", value: battery)
            }

            Divider()

            Button("Open VaderCleaner") {
                openMainWindow()
            }
            .keyboardShortcut("o")

            Button("Quit VaderCleaner") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 240)
    }

    /// RAM row carries an extra pressure-level badge so the user can see at a
    /// glance whether the system is under memory pressure without having to
    /// open the Health Monitor. The badge mirrors the Health Monitor card's
    /// color via the shared `StatusColor` mapping.
    private var ramRow: some View {
        HStack {
            Text("RAM")
                .foregroundStyle(.secondary)
            Spacer()
            Text(menuBar.formattedRAMUsage)
                .monospacedDigit()
            pressureBadge(
                label: menuBar.ramPressureLabel,
                color: menuBar.ramPressureColor
            )
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }

    /// Compact pill: a colored dot + status label. Sized small so it tucks
    /// into the trailing edge of the row without competing with the value.
    private func pressureBadge(label: String, color: StatusColor) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(swiftUIColor(for: color))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Maps the view-model's `StatusColor` (deliberately UI-framework-free
    /// for testability) to a SwiftUI `Color` at the leaf. Same mapping the
    /// Health Monitor card uses; kept local to the view rather than on the
    /// enum so the view-model layer stays SwiftUI-import-free.
    private func swiftUIColor(for status: StatusColor) -> Color {
        switch status {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .gray: return .gray
        }
    }

    private func openMainWindow() {
        // `openWindow(id:)` brings the existing main window to front, or opens
        // a new one if the user previously closed it. Following with
        // `NSApp.activate()` moves focus to the process so the window comes to
        // the foreground over other apps.
        openWindow(id: VaderCleanerApp.mainWindowID)
        NSApp.activate()
    }
}

#Preview {
    MenuBarContent()
        .environmentObject(MenuBarViewModel(service: SystemStatsService(autostart: false)))
}
