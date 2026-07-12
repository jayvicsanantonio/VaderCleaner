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

    /// The verdict the header renders: the shared derivation capped at Good
    /// until a first scan exists, so "Excellent" never sits directly above the
    /// Protection card's "Not scanned — run your first scan".
    private var displayedHealth: MacHealthStatus? {
        MenuBarViewModel.displayedHealth(menuBar.macHealth, hasScanned: malware.lastScanDate != nil)
    }

    /// The verdict's signature colour (gray while still measuring).
    private var verdictColor: Color { displayedHealth?.accentColor ?? Color(white: 0.6) }

    private var verdictTitle: String {
        displayedHealth?.title ?? String(localized: "Measuring…")
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
                // Leading placement keeps the button visually attached to the
                // detail text it acts on, instead of floating bottom-right.
                HStack {
                    Button(protectionCTA.label, action: protectionCTA.run)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    Spacer()
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

    // Titled "Storage" like the other tiles' category names; the volume name
    // reads as the unit line under the headline number instead.
    private var storageTile: some View {
        MenuTile(
            icon: "internaldrive",
            title: String(localized: "Storage"),
            value: menuBar.availableDiskSpace,
            label: storageLabel,
            status: MenuBarViewModel.diskStatusColor(menuBar.diskStats),
            usedFraction: menuBar.diskUsedFraction,
            action: (String(localized: "Clean Up"), { openSection(.systemJunk) }),
            open: { openSection(.systemJunk) },
            helpText: String(localized: "Open Cleanup")
        )
    }

    /// "available on Macintosh HD" — the unit line under the storage tile's
    /// headline number, carrying the volume name the title used to show.
    private var storageLabel: String {
        let format = String(
            localized: "available on %@",
            comment: "Storage tile line under the free-space number; %@ is the volume name."
        )
        return String(format: format, menuBar.bootVolumeName)
    }

    private var memoryTile: some View {
        MenuTile(
            icon: "memorychip",
            title: String(localized: "Memory"),
            value: menuBar.ramPressureLabel,
            label: String(localized: "pressure", comment: "Memory tile line under the pressure level."),
            status: menuBar.ramPressureColor,
            action: (String(localized: "Free Memory"), { openSection(.performance) }),
            open: { openSection(.performance) },
            helpText: String(localized: "Open Performance")
        )
    }

    private var batteryTile: some View {
        MenuTile(
            icon: menuBar.batterySymbolName,
            title: String(localized: "Battery"),
            value: batteryValue,
            label: batteryLabel,
            secondary: batterySecondary,
            status: menuBar.batteryStatusColor,
            open: { openSection(.healthMonitor) },
            helpText: String(localized: "Open Health Monitor")
        )
    }

    private var batteryValue: String {
        guard let charge = menuBar.batteryCharge else {
            return String(localized: "No battery")
        }
        return MenuBarViewModel.batteryChargeString(charge)
    }

    private var batteryLabel: String? {
        menuBar.batteryCharge.map { MenuBarViewModel.batteryStateString($0) }
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
            value: menuBar.formattedCPU,
            label: String(localized: "load", comment: "CPU tile line under the load percent."),
            status: menuBar.cpuLoadColor,
            open: { openSection(.healthMonitor) },
            helpText: String(localized: "Open Health Monitor")
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
                let shown = connectedDevices.devices.prefix(3)
                ForEach(shown) { device in
                    deviceRow(device)
                }
                // Never truncate silently: name how many devices didn't fit.
                if let overflow = MenuBarViewModel.hiddenDevicesLabel(
                    total: connectedDevices.devices.count,
                    shown: shown.count
                ) {
                    Text(overflow)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                // The shortcut glyph rides along in secondary weight so the
                // binding is discoverable without hunting for the tooltip.
                HStack(spacing: 6) {
                    Text("Open VaderCleaner")
                    Text(verbatim: "⌘O")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Text("Quit")
                    Text(verbatim: "⌘Q")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

/// Maps the view-model's framework-free `StatusColor` to a SwiftUI `Color`.
/// File-level so both the panel and its private tiles share one mapping.
private func swiftUIColor(for status: StatusColor) -> Color {
    switch status {
    case .green: return .green
    case .yellow: return .yellow
    case .red: return .red
    case .gray: return .gray
    }
}

/// One monitor tile: an icon + title row, a headline value over a small unit
/// label, an optional capacity bar, an optional secondary line, an optional
/// status dot, and an optional trailing action link. The whole tile is a
/// button that deep-links into the section owning the reading; the action
/// link is a sibling of that button (never its descendant) so each control
/// resolves clicks cleanly, matching the Protection card's pattern.
private struct MenuTile: View {
    let icon: String
    let title: String
    /// Headline reading, shown large — the number the user glances for
    /// ("679 GB", "23%").
    let value: String
    /// Small unit line under the value ("available on Macintosh HD", "load").
    var label: String?
    var secondary: String?
    var status: StatusColor?
    /// Used fraction (0…1) rendered as a thin capacity bar under the value,
    /// e.g. the storage tile's disk usage.
    var usedFraction: Double?
    /// Optional trailing link, e.g. ("Clean Up", action).
    var action: (label: String, run: () -> Void)?
    /// Whole-tile deep link into the section that owns this reading.
    let open: () -> Void
    let helpText: String

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
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
                        if let status {
                            Circle()
                                .fill(swiftUIColor(for: status))
                                .frame(width: 7, height: 7)
                                // The dot is color-only; VoiceOver speaks its
                                // meaning instead.
                                .accessibilityLabel(MenuBarViewModel.statusAccessibilityLabel(for: status))
                        }
                    }
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        // Live values roll to their next reading instead of
                        // blinking on the 2-second refresh.
                        .contentTransition(.numericText())
                        .animation(VaderMotion.telemetry, value: value)
                    if let label {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let usedFraction {
                        capacityBar(usedFraction)
                    }
                    if let secondary {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            if let action {
                HStack {
                    Spacer()
                    MenuActionLink(label: action.label, action: action.run)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(.white.opacity(hovered ? 0.08 : 0.05), in: .rect(cornerRadius: 12))
        .onHover { hovered = $0 }
        .animation(VaderMotion.hover, value: hovered)
    }

    /// The capacity bar shares the tile's accent while the reading is
    /// comfortable and switches to the status color once it needs attention,
    /// so a nearly-full disk's bar and dot agree.
    private var barFill: AnyShapeStyle {
        switch status {
        case .yellow: return AnyShapeStyle(Color.yellow)
        case .red:    return AnyShapeStyle(Color.red)
        default:      return AnyShapeStyle(.tint)
        }
    }

    private func capacityBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(barFill)
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
