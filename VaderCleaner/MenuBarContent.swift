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
    @Environment(ConnectedDevicesMonitor.self) private var connectedDevices
    @Environment(MalwareViewModel.self) private var malware
    @Environment(SmartScanViewModel.self) private var smartScan
    @Environment(MenuRouter.self) private var menuRouter
    @Environment(\.openWindow) private var openWindow

    /// Hover state for the two card-sized deep-link buttons. Local state keeps
    /// pointer movement re-rendering only the hovered surface.
    @State private var headerHovered = false
    @State private var protectionHovered = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                protectionCard
                LazyVGrid(columns: columns, spacing: 10) {
                    storageTile
                    memoryTile
                    batteryTile
                    cpuTile
                    networkTile
                    connectedDevicesTile
                }
                recommendationCard
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 380)
        .background(panelBackground)
        // The Mac Health panel shares the Health Monitor section's blue accent
        // for every tinted control (icons, links, buttons, progress). Semantic
        // status colors (health verdict, memory pressure, protection) stay as-is
        // so they keep conveying meaning.
        .tint(healthAccent)
        // Refresh the device list each time the panel opens — devices change
        // infrequently, so an on-open read beats a dedicated poll timer.
        .task { connectedDevices.refresh() }
    }

    // MARK: - Header

    /// The Mac Health panel shares the Health Monitor section's colour identity
    /// so the popup and the in-app section read as one product.
    private var healthTheme: SectionTheme { NavigationSection.healthMonitor.theme }
    private var healthAccent: Color { healthTheme.accent }

    /// The verdict's signature colour (gray while still measuring).
    private var verdictColor: Color { menuBar.macHealth?.accentColor ?? Color(white: 0.6) }

    private var verdictTitle: String {
        menuBar.macHealth?.title ?? String(localized: "Measuring…")
    }

    private var header: some View {
        Button {
            openSection(.healthMonitor)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Mac Health:")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(verdictTitle)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(verdictColor)
                        // Chevron affordance: the header deep-links into the
                        // Health Monitor, and brightens under the pointer.
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(headerHovered ? 0.8 : 0.35))
                    }
                    Text("\(menuBar.deviceName) · \(menuBar.systemUptimeString)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.95), healthAccent.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(headerBackground)
            .overlay(Color.white.opacity(headerHovered ? 0.05 : 0).allowsHitTesting(false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { headerHovered = $0 }
        .animation(VaderMotion.hover, value: headerHovered)
        .help("Open Health Monitor")
    }

    private var headerBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.13, blue: 0.42),
                    Color(red: 0.12, green: 0.09, blue: 0.28)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [healthAccent.opacity(0.32), .clear],
                center: UnitPoint(x: 0.85, y: 0.3),
                startRadius: 4,
                endRadius: 180
            )
        }
    }

    // MARK: - Protection card

    /// Whether the last scan surfaced unresolved threats.
    private var hasThreats: Bool {
        if case .results(let threats) = malware.phase { return !threats.isEmpty }
        return false
    }

    /// The scanner currently running, if any — Smart Scan (whose results seed
    /// this card) or Protection's own scanner, including its install check
    /// and database update. `nil` when no scan is in flight.
    private var scanActivity: MenuBarViewModel.ScanActivity? {
        if case .scanning = smartScan.phase { return .smartScan }
        switch malware.phase {
        case .checkingClamAV, .updatingDatabase, .scanning: return .threatScan
        default: return nil
        }
    }

    private var protectionStatus: MenuBarViewModel.ProtectionStatus {
        MenuBarViewModel.protectionStatus(
            hasThreats: hasThreats,
            hasScanned: malware.lastScanDate != nil,
            isScanning: scanActivity != nil
        )
    }

    private var protectionColor: Color {
        switch protectionStatus {
        case .protected: return .green
        case .threatsFound: return .red
        case .notScanned: return .secondary
        case .scanning: return healthAccent
        }
    }

    private var protectionIcon: String {
        switch protectionStatus {
        case .protected: return "checkmark.shield.fill"
        case .threatsFound: return "exclamationmark.shield.fill"
        case .notScanned, .scanning: return "shield"
        }
    }

    /// Detail line under the Protection title. A never-scanned Mac explains
    /// what a first scan buys instead of repeating the "Not scanned" status
    /// label; a running scan narrates the activity; otherwise it shows scan
    /// recency.
    private var protectionDetail: String {
        switch protectionStatus {
        case .notScanned:
            return String(
                localized: "Run your first scan to enable protection.",
                comment: "Protection card detail before any scan has run."
            )
        case .scanning:
            // `scanActivity` is non-nil whenever the status is `.scanning`;
            // the fallback only satisfies exhaustiveness.
            return MenuBarViewModel.scanningDetail(for: scanActivity ?? .threatScan)
        case .protected, .threatsFound:
            return MenuBarViewModel.lastScanString(malware.lastScanDate)
        }
    }

    /// The Protection card's action button when the status needs the user to
    /// act: first scan for a never-scanned Mac (Smart Scan covers threats and
    /// seeds this card), review for live threats, nothing while protected or
    /// mid-scan.
    private var protectionCTA: (label: String, run: () -> Void)? {
        switch protectionStatus {
        case .notScanned:
            return (
                String(localized: "Scan Now", comment: "Protection card button that starts a first scan."),
                { openSection(.smartScan, startScan: true) }
            )
        case .threatsFound:
            return (
                String(localized: "Review Threats", comment: "Protection card button that opens the threats list."),
                { openSection(.malwareRemoval) }
            )
        case .protected, .scanning:
            return nil
        }
    }

    private var protectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The informational area is its own button (sibling of the CTA,
            // never its ancestor) so each control resolves clicks cleanly.
            // It deep-links to the Smart Scan section the card is named for,
            // except mid-threat-scan when the activity lives in Protection.
            Button {
                openSection(scanActivity == .threatScan ? .malwareRemoval : .smartScan)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: protectionIcon)
                        .font(.title2)
                        .foregroundStyle(protectionColor)
                        // Motion as meaning: the shield breathes only while a
                        // scan is actually running.
                        .symbolEffect(.pulse, isActive: protectionStatus == .scanning)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(MenuBarViewModel.protectionCardTitle(for: scanActivity))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if protectionStatus == .scanning {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(MenuBarViewModel.protectionStatusLabel(protectionStatus))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(protectionColor)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(protectionDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(scanActivity == .threatScan ? "Open Protection" : "Open Smart Scan")
            if let protectionCTA {
                HStack {
                    Spacer()
                    Button(protectionCTA.label, action: protectionCTA.run)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(protectionHovered ? 0.08 : 0.05), in: .rect(cornerRadius: 12))
        .onHover { protectionHovered = $0 }
        .animation(VaderMotion.hover, value: protectionHovered)
    }

    // MARK: - Tiles

    private var storageTile: some View {
        MenuTile(
            icon: "internaldrive",
            title: menuBar.bootVolumeName,
            primary: availableLine,
            usedFraction: menuBar.diskUsedFraction,
            action: (String(localized: "Clean Up"), { openSection(.systemJunk) })
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
            action: (String(localized: "Free Memory"), { openSection(.performance) })
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
            icon: menuBar.batterySymbolName,
            title: String(localized: "Battery"),
            primary: batteryPrimary,
            secondary: batterySecondary,
            statusColor: menuBar.batteryStatusColor.map { swiftUIColor(for: $0) }
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

    // Uptime lives in the panel header next to the device name — it is a
    // machine-level fact, not CPU telemetry.
    private var cpuTile: some View {
        MenuTile(
            icon: "cpu",
            title: cpuTitle,
            primary: cpuLine,
            statusColor: swiftUIColor(for: menuBar.cpuLoadColor)
        )
    }

    /// Title carries the temperature when the SMC reports one, e.g. "CPU · 50°C";
    /// otherwise just "CPU".
    private var cpuTitle: String {
        if let temp = menuBar.cpuTemperature {
            return "\(String(localized: "CPU")) · \(temp)"
        }
        return String(localized: "CPU")
    }

    private var cpuLine: String {
        let format = String(
            localized: "Load: %@",
            comment: "CPU tile line; %@ is processor load percent, e.g. Load: 20%"
        )
        return String(format: format, menuBar.formattedCPU)
    }

    // MARK: - Network tile

    // Titled "Network" like the other tiles' category names; the SSID (raw
    // router noise like "ATTQ3gAepM") reads as the detail line instead.
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
            Text(menuBar.wifiNetworkName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(menuBar.networkDownString)
                        .font(.caption)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(VaderMotion.telemetry, value: menuBar.networkDownString)
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(menuBar.networkUpString)
                        .font(.caption)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(VaderMotion.telemetry, value: menuBar.networkUpString)
                }
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

    // MARK: - Connected devices tile

    private var connectedDevicesTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cable.connector")
                    .font(.callout)
                    .foregroundStyle(.tint)
                Text("Connected Devices")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if connectedDevices.devices.isEmpty {
                Text("None connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(connectedDevices.devices.prefix(3)) { device in
                    deviceRow(device)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    private func deviceRow(_ device: ConnectedDevice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: device.kind == .bluetooth ? "dot.radiowaves.left.and.right" : "externaldrive")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(device.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                // Long names middle-truncate; the tooltip carries the full name.
                .help(device.name)
            Spacer(minLength: 0)
            if let battery = device.batteryPercent {
                Text("\(battery)%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if device.kind == .volume {
                Button {
                    connectedDevices.eject(device)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Eject \(device.name)")
            }
        }
    }

    @ViewBuilder
    private var speedTestControl: some View {
        switch menuBar.speedTestState {
        case .idle:
            MenuActionLink(label: String(localized: "Test Speed")) { Task { await menuBar.runSpeedTest() } }
        case .running:
            ProgressView().controlSize(.small)
        case .result(let mbps):
            MenuActionLink(label: MenuBarViewModel.speedTestResultString(mbps)) { Task { await menuBar.runSpeedTest() } }
                .help("Measured download speed — click to test again")
        case .failed:
            MenuActionLink(label: String(localized: "Retry"), color: .orange) { Task { await menuBar.runSpeedTest() } }
        }
    }

    // MARK: - Recommendation

    /// State-driven recommendation, or `nil` when the Protection card already
    /// carries the panel's call to action (see `MenuBarViewModel.recommendation`).
    private var recommendation: MenuBarViewModel.Recommendation? {
        MenuBarViewModel.recommendation(
            protection: protectionStatus,
            disk: menuBar.diskStats,
            pressure: menuBar.ramPressureLevel,
            lastScanDate: malware.lastScanDate
        )
    }

    @ViewBuilder
    private var recommendationCard: some View {
        if let recommendation {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's Recommendation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(recommendation.title)
                        .font(.subheadline.weight(.semibold))
                    Text(recommendation.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(recommendation.actionLabel) {
                            open(recommendation)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
        }
    }

    /// Maps the view-model's framework-free recommendation target onto the
    /// app's navigation sections and deep-links there.
    private func open(_ recommendation: MenuBarViewModel.Recommendation) {
        let section: NavigationSection
        switch recommendation.target {
        case .smartScan:   section = .smartScan
        case .cleanup:     section = .systemJunk
        case .performance: section = .performance
        }
        openSection(section, startScan: recommendation.startsScan)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button(action: openMainWindow) {
                Text("Open VaderCleaner")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o")
            .help("Open the main window (⌘O)")

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")

            // An explicit word rather than a power glyph — next to system
            // telemetry a power symbol reads as "shut down the Mac".
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Quit VaderCleaner (⌘Q)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Background + helpers

    private var panelBackground: some View {
        LinearGradient(
            colors: [healthTheme.backdropTop, healthTheme.backdropBottom],
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

    /// Deep-links into a main-window section: records the request on the router,
    /// then opens and activates the window so ContentView navigates there.
    private func openSection(_ section: NavigationSection, startScan: Bool = false) {
        menuRouter.request(section, startScan: startScan)
        openMainWindow()
    }
}

/// One monitor tile: an icon + title row, a primary metric line, an optional
/// capacity bar, an optional secondary line, an optional status dot, and an
/// optional trailing action link.
private struct MenuTile: View {
    let icon: String
    let title: String
    let primary: String
    var secondary: String?
    var statusColor: Color?
    /// Used fraction (0…1) rendered as a thin capacity bar under the primary
    /// line, e.g. the storage tile's disk usage.
    var usedFraction: Double?
    /// Optional trailing link, e.g. ("Clean Up", action).
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
                // Live values roll to their next reading instead of blinking
                // on the 2-second refresh.
                .contentTransition(.numericText())
                .animation(VaderMotion.telemetry, value: primary)
            if let usedFraction {
                capacityBar(usedFraction)
            }
            if let secondary {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let action {
                HStack {
                    Spacer()
                    MenuActionLink(label: action.label, action: action.run)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    private func capacityBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.tint)
                    .frame(width: max(4, geo.size.width * fraction))
                    .animation(VaderMotion.telemetry, value: fraction)
            }
        }
        .frame(height: 4)
        .padding(.vertical, 2)
    }
}

/// Caption-weight link used for tile actions ("Clean Up", "Test Speed"):
/// underlines under the pointer and pads its hit target beyond the bare text.
private struct MenuActionLink: View {
    let label: String
    var color: Color?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                .underline(hovered)
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(VaderMotion.hover, value: hovered)
    }
}

#Preview {
    let previewDefaults = UserDefaults(suiteName: "menu-preview")!
    let prefs = PreferencesStore(defaults: previewDefaults)
    return MenuBarContent()
        .environment(MenuBarViewModel(service: SystemStatsService(autostart: false)))
        .environment(ConnectedDevicesMonitor(autoRefresh: false))
        .environment(MalwareViewModel.live(
            dispatcher: NotificationManager(),
            preferences: prefs,
            settings: ProtectionSettingsStore(defaults: previewDefaults)
        ))
        .environment(SmartScanViewModel.live(
            exclusions: ExclusionsStore(defaults: previewDefaults),
            settings: SmartScanSettingsStore(defaults: previewDefaults)
        ))
        .environment(MenuRouter())
}
