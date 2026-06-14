// MenuBarContent.swift
// The menu bar panel — a Mac Health header, a grid of live system tiles (Storage, Memory, Battery, CPU), a recommendation card, and a footer, driven by MenuBarViewModel / SystemStatsService.

import SwiftUI
import AppKit

/// Wide panel presented when the user clicks the menu bar icon. Mirrors the
/// CleanMyMac menu's shape — a Mac Health verdict header, a 2-column grid of
/// monitor tiles, a "Today's Recommendation" card, and a footer — while showing
/// only VaderCleaner's real telemetry. Values refresh on the same 2-second
/// cadence as the Health Monitor.
struct MenuBarContent: View {

    @Environment(MenuBarViewModel.self) private var menuBar
    @Environment(\.openWindow) private var openWindow

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                LazyVGrid(columns: columns, spacing: 10) {
                    storageTile
                    memoryTile
                    batteryTile
                    cpuTile
                    networkTile
                }
                recommendationCard
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 380)
        .background(panelBackground)
    }

    // MARK: - Header

    /// The verdict's signature colour (gray while still measuring).
    private var verdictColor: Color { menuBar.macHealth?.accentColor ?? Color(white: 0.6) }

    private var verdictTitle: String {
        menuBar.macHealth?.title ?? String(localized: "Measuring…")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Mac Health:")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(verdictTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(verdictColor)
                }
                Text(menuBar.deviceName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Image(systemName: "laptopcomputer")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white.opacity(0.95), verdictColor.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerBackground)
    }

    private var headerBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.07, blue: 0.22),
                    Color(red: 0.20, green: 0.10, blue: 0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [verdictColor.opacity(0.28), .clear],
                center: UnitPoint(x: 0.85, y: 0.3),
                startRadius: 4,
                endRadius: 180
            )
        }
    }

    // MARK: - Tiles

    private var storageTile: some View {
        MenuTile(
            icon: "internaldrive",
            title: menuBar.bootVolumeName,
            primary: availableLine,
            action: (String(localized: "Free Up"), openMainWindow)
        )
    }

    private var availableLine: String {
        let format = String(
            localized: "Available: %@",
            comment: "Storage tile line; %@ is free space, e.g. Available: 434.3 GB"
        )
        return String(format: format, menuBar.availableDiskSpace)
    }

    private var memoryTile: some View {
        MenuTile(
            icon: "memorychip",
            title: String(localized: "Memory"),
            primary: memoryLine,
            statusColor: swiftUIColor(for: menuBar.ramPressureColor),
            action: (String(localized: "Free Up"), openMainWindow)
        )
    }

    private var memoryLine: String {
        let format = String(
            localized: "Pressure: %@",
            comment: "Memory tile line; %@ is the memory-pressure level, e.g. Pressure: Nominal"
        )
        return String(format: format, menuBar.ramPressureLabel)
    }

    private var batteryTile: some View {
        MenuTile(
            icon: "battery.100",
            title: String(localized: "Battery"),
            primary: batteryPrimary,
            secondary: batterySecondary
        )
    }

    private var batteryPrimary: String {
        guard let charge = menuBar.batteryCharge else {
            return String(localized: "No battery")
        }
        return "\(MenuBarViewModel.batteryChargeString(charge)) · \(MenuBarViewModel.batteryStateString(charge))"
    }

    private var batterySecondary: String? {
        guard let temp = menuBar.batteryCharge?.temperatureCelsius else { return nil }
        return MenuBarViewModel.batteryTemperatureString(temp)
    }

    private var cpuTile: some View {
        MenuTile(
            icon: "cpu",
            title: String(localized: "CPU"),
            primary: cpuLine
        )
    }

    private var cpuLine: String {
        let format = String(
            localized: "Load: %@",
            comment: "CPU tile line; %@ is processor load percent, e.g. Load: 20%"
        )
        return String(format: format, menuBar.formattedCPU)
    }

    // MARK: - Network tile

    private var networkTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wifi")
                    .font(.callout)
                    .foregroundStyle(.tint)
                Text("Network")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(menuBar.networkDownString)
                    .font(.caption)
                    .monospacedDigit()
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(menuBar.networkUpString)
                    .font(.caption)
                    .monospacedDigit()
            }
            HStack {
                Spacer()
                speedTestControl
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var speedTestControl: some View {
        switch menuBar.speedTestState {
        case .idle:
            Button(String(localized: "Test Speed")) { Task { await menuBar.runSpeedTest() } }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
        case .running:
            ProgressView().controlSize(.small)
        case .result(let mbps):
            Button(MenuBarViewModel.speedTestResultString(mbps)) { Task { await menuBar.runSpeedTest() } }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
        case .failed:
            Button(String(localized: "Retry")) { Task { await menuBar.runSpeedTest() } }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Recommendation

    private var recommendationCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Today's Recommendation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("It's time to care for your Mac!")
                    .font(.subheadline.weight(.semibold))
                Text("Run Smart Scan to find junk, large files, and threats in one pass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(String(localized: "Run Smart Scan"), action: openMainWindow)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: openMainWindow) {
                Text("Open VaderCleaner")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o")

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Quit VaderCleaner")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Background + helpers

    private var panelBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.06, blue: 0.16),
                Color(red: 0.06, green: 0.04, blue: 0.10)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Maps the view-model's framework-free `StatusColor` to a SwiftUI `Color`.
    private func swiftUIColor(for status: StatusColor) -> Color {
        switch status {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .gray: return .gray
        }
    }

    private func openMainWindow() {
        // Brings the existing main window forward, or opens one if it was
        // closed, then activates the process so it surfaces over other apps.
        openWindow(id: VaderCleanerApp.mainWindowID)
        NSApp.activate()
    }
}

/// One monitor tile: an icon + title row, a primary metric line, an optional
/// secondary line, an optional status dot, and an optional trailing action link.
private struct MenuTile: View {
    let icon: String
    let title: String
    let primary: String
    var secondary: String?
    var statusColor: Color?
    /// Optional trailing link, e.g. ("Free Up", action).
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let statusColor {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                }
            }
            Text(primary)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let secondary {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let action {
                HStack {
                    Spacer()
                    Button(action.label, action: action.run)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
    }
}

#Preview {
    MenuBarContent()
        .environment(MenuBarViewModel(service: SystemStatsService(autostart: false)))
}
