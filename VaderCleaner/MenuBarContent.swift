// MenuBarContent.swift
// SwiftUI view rendering the menu bar extra popover — RAM row, disk row, Open and Quit actions.

import SwiftUI
import AppKit

/// Popover content presented when the user clicks the menu bar icon. Uses a
/// fixed-width column so the layout stays stable as Prompt 10 swaps in live
/// telemetry.
struct MenuBarContent: View {

    @EnvironmentObject private var menuBar: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statRow(label: "RAM", value: menuBar.formattedRAMUsage)
            statRow(label: "Disk", value: menuBar.formattedDiskSpace)

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
        .frame(width: 220)
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
        .environmentObject(MenuBarViewModel())
}
