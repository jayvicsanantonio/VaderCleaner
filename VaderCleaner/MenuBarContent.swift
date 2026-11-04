// MenuBarContent.swift
// The menu bar panel — a one-line verdict header, every issue that needs attention, a grid of live readings, connected devices, verb shortcuts, and a footer, driven by MenuBarViewModel / SystemStatsService.

import SwiftUI
import AppKit
import VaderCleanerCore

/// Panel presented when the user clicks the menu bar icon. Built around a
/// three-beat hierarchy an ordinary person can read in two seconds:
///
///   1. **Glance** — a compact header: a status badge, a plain-language
///      verdict that folds in Protection ("2 things need attention"), and one
///      line of supporting facts ("Protected · Last scan 2 days ago").
///   2. **Act** — every problem that needs attention, worst first, each with
///      its own action; only the most urgent one is styled loudly. With
///      nothing wrong this collapses to one quiet line, so a healthy Mac
///      never gets a shouting button. A running scan adds a progress strip.
///   3. **Dive** — a 2×2 grid of live readings (Storage, Memory, CPU,
///      Network) that stay neutral until a reading is off, connected
///      devices, four verb shortcuts, and a footer.
///
/// Values refresh on the same cadence as the Health Monitor.
struct MenuBarContent: View {

    @Environment(MenuBarViewModel.self) private var menuBar
    @Environment(PreferencesStore.self) private var preferences
    @Environment(SystemStatsService.self) private var systemStats
    @Environment(ConnectedDevicesMonitor.self) private var connectedDevices
    @Environment(MalwareViewModel.self) private var malware
    @Environment(SmartScanViewModel.self) private var smartScan
    @Environment(MenuRouter.self) private var menuRouter
    @Environment(\.openWindow) private var openWindow

    /// Hover state for the header deep-link surface.
    @State private var headerHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                attentionArea
                readingsGrid
                devicesCard
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            quickActions
            Divider()
            footer
        }
        .frame(width: 360)
        .background(panelBackground)
        // Shared Health Monitor blue for every tinted control; semantic status
        // colors (verdict, issues, readings) stay as-is so they keep
        // conveying meaning.
        .tint(healthAccent)
        // Refresh the device list each time the panel opens — devices change
        // infrequently, so an on-open read beats a dedicated poll timer.
        .task { connectedDevices.refresh() }
        // The panel is the main consumer of live stats; holding a claim only
        // while it's open is what keeps polling from running all day.
        .onAppear { systemStats.beginUpdates() }
        .onDisappear { systemStats.endUpdates() }
    }

    // MARK: - Theme

    /// The panel shares the Health Monitor section's colour identity so the
    /// popup and the in-app section read as one product.
    private var healthTheme: SectionTheme { NavigationSection.healthMonitor.theme }
    private var healthAccent: Color { healthTheme.accent }

    /// One continuous gradient behind the whole panel, with the accent
    /// blooming down from behind the header.
    private var panelBackground: some View {
        ZStack {
            LinearGradient(
                colors: [healthTheme.backdropTop, healthTheme.backdropBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [healthAccent.opacity(0.22), .clear],
                center: UnitPoint(x: 0.15, y: 0.0),
                startRadius: 8,
                endRadius: 240
            )
        }
    }

    // MARK: - Scan state

    /// Whether the last scan surfaced unresolved threats.
    private var hasThreats: Bool {
        if case .results(let threats) = malware.phase { return !threats.isEmpty }
        return false
    }

    /// The scanner currently running, if any — Smart Scan (whose results seed
    /// protection status) or Protection's own scanner, including its install
    /// check and database update. `nil` when no scan is in flight.
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

    /// Every urgent problem, worst first.
    private var attention: [MenuBarViewModel.NextStep] {
        MenuBarViewModel.attentionSteps(
            protection: protectionStatus,
            disk: menuBar.diskStats,
            pressure: menuBar.ramPressureLevel
        )
    }

    /// The single next step when nothing is urgent: a first scan, a stale-scan
    /// nudge, or the all-clear.
    private var nextStep: MenuBarViewModel.NextStep? {
        MenuBarViewModel.nextStep(
            protection: protectionStatus,
            disk: menuBar.diskStats,
            pressure: menuBar.ramPressureLevel,
            lastScanDate: malware.lastScanDate
        )
    }

    // MARK: - Header

    /// The disk-and-battery verdict, capped at Good until a first scan exists,
    /// then folded together with the attention list so the header never
    /// praises a Mac above a threat.
    private var verdict: MenuBarViewModel.PanelVerdict {
        MenuBarViewModel.panelVerdict(
            health: MenuBarViewModel.displayedHealth(menuBar.macHealth, hasScanned: malware.lastScanDate != nil),
            attention: attention
        )
    }

    private var headerDetail: String {
        MenuBarViewModel.panelDetail(
            protection: protectionStatus,
            lastScanDate: malware.lastScanDate,
            includesProtection: preferences.isPanelRowEnabled(.protection)
        )
    }

    private func toneColor(_ tone: MenuBarViewModel.PanelVerdict.Tone) -> Color {
        switch tone {
        case .measuring: return Color(white: 0.6)
        case .good:      return .green
        case .caution:   return .orange
        case .alert:     return .red
        }
    }

    /// Glance zone: status badge, verdict, and supporting facts on one row.
    /// The whole header deep-links into the Health Monitor; the Mac's name
    /// and uptime ride in its tooltip.
    private var header: some View {
        Button {
            openSection(.healthMonitor)
        } label: {
            HStack(spacing: 12) {
                verdictBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(verdict.headline)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(headerDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // Chevron affordance: the header deep-links, and brightens
                // under the pointer.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(headerHovered ? 0.8 : 0.35))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Color.white.opacity(headerHovered ? 0.04 : 0).allowsHitTesting(false))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .onHover { headerHovered = $0 }
        .animation(VaderMotion.hover, value: headerHovered)
        .help("\(menuBar.deviceName) · \(menuBar.systemUptimeString) — Open Health Monitor")
        .accessibilityIdentifier("menuBar.header")
    }

    /// A tone-coloured disc carrying the verdict as a shape as well as a
    /// sentence; a spinner while the first reading is still being measured.
    private var verdictBadge: some View {
        let color = toneColor(verdict.tone)
        return ZStack {
            Circle().fill(color.opacity(0.2))
            switch verdict.tone {
            case .measuring:
                ProgressView().controlSize(.small)
            case .good:
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(color)
            case .caution:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(color)
            case .alert:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 36, height: 36)
        .animation(VaderMotion.telemetry, value: verdict.tone)
        // Decorative alongside the headline; VoiceOver reads the words.
        .accessibilityHidden(true)
    }

    // MARK: - Attention area

    /// Act zone. A running scan narrates itself; every urgent problem gets
    /// its own row; with nothing urgent, a first-scan or stale-scan
    /// suggestion gets a card and the all-clear gets one quiet line.
    @ViewBuilder
    private var attentionArea: some View {
        VStack(spacing: 8) {
            if let scanActivity {
                scanningStrip(scanActivity)
            }
            ForEach(Array(attention.enumerated()), id: \.element.target) { index, step in
                // Only the worst problem is styled loudly, and not while a
                // scan already holds the user's attention.
                issueRow(step, isPrimary: index == 0 && scanActivity == nil)
            }
            if attention.isEmpty, scanActivity == nil, let nextStep {
                if nextStep.urgency == .allClear {
                    allClearLine(nextStep)
                } else {
                    issueRow(nextStep, isPrimary: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menuBar.attention")
    }

    /// Live progress strip while a scan runs: a breathing shield, the scan's
    /// name, and the rolling item tally that proves the scan is advancing.
    /// Clicking it opens the section doing the work.
    private func scanningStrip(_ activity: MenuBarViewModel.ScanActivity) -> some View {
        Button {
            openSection(activity == .threatScan ? .malwareRemoval : .smartScan)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "shield")
                    .font(.title3)
                    .foregroundStyle(healthAccent)
                    // Motion as meaning: the shield breathes only while a
                    // scan is actually running.
                    .symbolEffect(.pulse, isActive: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MenuBarViewModel.protectionCardTitle(for: activity))
                        .font(.subheadline.weight(.semibold))
                    Text(MenuBarViewModel.scanningDetail(for: activity, itemsScanned: smartScan.scannedItemCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // The live item tally rolls instead of blinking as
                        // the walks report progress.
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(VaderMotion.telemetry, value: smartScan.scannedItemCount)
                }
                Spacer(minLength: 8)
                ProgressView()
                    .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(activity == .threatScan ? "Open Protection" : "Open Smart Scan")
    }

    /// The step's signature colour: red for threats, orange for the other
    /// urgent conditions, and the panel accent for suggestions.
    private func stepColor(_ step: MenuBarViewModel.NextStep) -> Color {
        switch step.urgency {
        case .urgent:    return step.target == .threats ? .red : .orange
        case .suggested: return healthAccent
        case .allClear:  return .green
        }
    }

    private func stepIcon(_ step: MenuBarViewModel.NextStep) -> String {
        switch step.target {
        case .threats:     return "exclamationmark.shield.fill"
        case .cleanup:     return "internaldrive.fill"
        case .performance: return "memorychip"
        case .smartScan:   return "sparkles"
        }
    }

    /// One problem or suggestion: an icon in the step's colour, the title and
    /// detail in plain language, and its action on the trailing edge. The
    /// primary row's button fills with the step's colour; the rest use glass
    /// so only one control on the panel shouts.
    private func issueRow(_ step: MenuBarViewModel.NextStep, isPrimary: Bool) -> some View {
        let color = stepColor(step)
        return HStack(spacing: 10) {
            Image(systemName: stepIcon(step))
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.18), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            stepButton(step, isPrimary: isPrimary, color: color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(step.urgency == .urgent ? 0.12 : 0.06), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func stepButton(_ step: MenuBarViewModel.NextStep, isPrimary: Bool, color: Color) -> some View {
        if isPrimary {
            Button(step.actionLabel) { open(step) }
                .buttonStyle(.vaderProminent)
                // The prominent style fills with the section accent from the
                // environment; hand it the step's colour so urgency reads in
                // the button itself.
                .environment(\.sectionAccent, color)
                .fixedSize()
        } else {
            Button(step.actionLabel) { open(step) }
                .buttonStyle(.vaderGlass)
        }
    }

    /// The all-clear: one quiet line and a glass button, so a healthy Mac
    /// reads as calm instead of being handed a loud call to action.
    private func allClearLine(_ step: MenuBarViewModel.NextStep) -> some View {
        HStack(spacing: 8) {
            Text(step.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(step.actionLabel) { open(step) }
                .buttonStyle(.vaderGlass)
        }
        .padding(.horizontal, 2)
    }

    /// Deep-links to the section that can act on a step.
    private func open(_ step: MenuBarViewModel.NextStep) {
        openSection(Self.section(for: step.target), startScan: step.startsScan)
    }

    /// Maps the view-model's framework-free step target onto the app's
    /// navigation sections.
    static func section(for target: MenuBarViewModel.NextStep.Target) -> NavigationSection {
        switch target {
        case .smartScan:   return .smartScan
        case .cleanup:     return .systemJunk
        case .performance: return .performance
        case .threats:     return .malwareRemoval
        }
    }

    // MARK: - Readings grid

    /// Dive zone: the readings the user has left switched on, two to a row.
    private var readingsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            if preferences.isPanelRowEnabled(.storage) { storageTile.accessibilityIdentifier("menuBar.tile.storage") }
            if preferences.isPanelRowEnabled(.memory) { memoryTile.accessibilityIdentifier("menuBar.tile.memory") }
            if preferences.isPanelRowEnabled(.cpu) { cpuTile.accessibilityIdentifier("menuBar.tile.cpu") }
            if preferences.isPanelRowEnabled(.network) { networkTile.accessibilityIdentifier("menuBar.tile.network") }
        }
    }

    private func highlight(_ status: StatusColor) -> Color? {
        MenuBarViewModel.highlightedStatus(status).map(swiftUIColor(for:))
    }

    private var storageTile: some View {
        ReadingTile(
            icon: "internaldrive",
            iconTint: NavigationSection.systemJunk.iconAccent,
            title: String(localized: "Storage"),
            value: storageValue,
            footer: .bar(menuBar.diskUsedFraction),
            highlight: highlight(MenuBarViewModel.diskStatusColor(menuBar.diskStats)),
            open: { openSection(.systemJunk) },
            helpText: String(localized: "Open Cleanup")
        )
    }

    private var memoryTile: some View {
        ReadingTile(
            icon: "memorychip",
            iconTint: NavigationSection.performance.iconAccent,
            title: String(localized: "Memory"),
            value: menuBar.ramPressureLabel,
            footer: .bar(menuBar.memoryUsedFraction),
            highlight: highlight(menuBar.ramPressureColor),
            open: { openSection(.performance) },
            helpText: String(localized: "Open Performance")
        ) {
            if MenuBarViewModel.showsMemoryFlush(pressure: menuBar.ramPressureLevel, state: menuBar.memoryFlushState) {
                memoryFlushControl
            }
        }
    }

    private var cpuTile: some View {
        ReadingTile(
            icon: "cpu",
            iconTint: healthAccent,
            title: String(localized: "CPU"),
            value: cpuValue,
            footer: .bar(menuBar.cpuFraction),
            highlight: highlight(menuBar.cpuLoadColor),
            open: { openSection(.healthMonitor) },
            helpText: String(localized: "Open Health Monitor")
        )
    }

    /// Network has no section to open, so its tile is not a deep link. It
    /// leads with "Idle" or the download rate, then the upload rate or the
    /// network's name; the speed test sits in the corner.
    private var networkTile: some View {
        let value: String
        let caption: String
        switch menuBar.networkActivity {
        case .idle:
            value = String(localized: "Idle", comment: "Network tile value when there is no meaningful traffic.")
            caption = menuBar.wifiNetworkName
        case .active(let down, let up):
            value = "↓ \(down)"
            caption = "↑ \(up)"
        }
        return ReadingTile(
            icon: "wifi",
            iconTint: NavigationSection.spaceLens.iconAccent,
            title: String(localized: "Network"),
            value: value,
            footer: .caption(caption),
            highlight: nil,
            open: nil,
            helpText: menuBar.wifiNetworkName
        ) {
            speedTestControl
        }
    }

    /// "679 GB free" — free space is the number an ordinary person actually
    /// wants.
    private var storageValue: String {
        let format = String(
            localized: "%@ free",
            comment: "Storage tile value; %@ is the free-space amount."
        )
        return String(format: format, menuBar.availableDiskSpace)
    }

    /// "23%" or "23% · 50°C" when the SMC reports a temperature.
    private var cpuValue: String {
        if let temp = menuBar.cpuTemperature {
            return "\(menuBar.formattedCPU) · \(temp)"
        }
        return menuBar.formattedCPU
    }

    /// The Memory tile's inline action: purges inactive RAM through the
    /// privileged helper right from the panel — no main-window round trip —
    /// with a spinner in flight, a confirmation once done (clickable to purge
    /// again), and an orange retry after a failure.
    @ViewBuilder
    private var memoryFlushControl: some View {
        switch menuBar.memoryFlushState {
        case .running:
            ProgressView().controlSize(.mini)
        case .idle, .flushed, .failed:
            if let label = MenuBarViewModel.memoryFlushLabel(for: menuBar.memoryFlushState) {
                MenuActionLink(
                    label: label,
                    color: menuBar.memoryFlushState == .failed ? .orange : nil
                ) {
                    Task { await menuBar.flushMemory() }
                }
                .help("Purge inactive memory")
            }
        }
    }

    @ViewBuilder
    private var speedTestControl: some View {
        switch menuBar.speedTestState {
        case .idle:
            MenuActionLink(label: String(localized: "Test Speed")) { Task { await menuBar.runSpeedTest() } }
        case .running:
            ProgressView().controlSize(.mini)
        case .result(let mbps):
            MenuActionLink(label: MenuBarViewModel.speedTestResultString(mbps)) { Task { await menuBar.runSpeedTest() } }
                .help("Measured download speed — click to test again")
        case .failed:
            MenuActionLink(label: String(localized: "Retry"), color: .orange) { Task { await menuBar.runSpeedTest() } }
        }
    }

    // MARK: - Devices

    /// Connected Bluetooth devices and ejectable volumes, in a card of their
    /// own — they are attached to the Mac, not to its Wi-Fi. At most three,
    /// with an explicit overflow line so the list never truncates silently.
    @ViewBuilder
    private var devicesCard: some View {
        if preferences.isPanelRowEnabled(.devices), !connectedDevices.devices.isEmpty {
            let shown = connectedDevices.devices.prefix(3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(shown) { device in
                    deviceRow(device)
                }
                if let overflow = MenuBarViewModel.hiddenDevicesLabel(
                    total: connectedDevices.devices.count,
                    shown: shown.count
                ) {
                    Text(overflow)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
        }
    }

    private func deviceRow(_ device: ConnectedDevice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: device.kind == .bluetooth ? "dot.radiowaves.left.and.right" : "externaldrive")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
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
                    .monospacedDigit()
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

    // MARK: - Quick actions

    /// Four shortcuts named for what they do, not where they live. Order
    /// follows the rail.
    static let quickActionSections: [NavigationSection] = [.smartScan, .systemJunk, .applications, .spaceLens]

    /// A shortcut's verb label, falling back to the section's own title.
    static func quickActionLabel(for section: NavigationSection) -> String {
        switch section {
        case .systemJunk:   return String(localized: "Clean Up")
        case .applications: return String(localized: "Uninstall")
        default:            return section.title
        }
    }

    private var quickActions: some View {
        HStack(spacing: 4) {
            ForEach(Self.quickActionSections) { section in
                QuickAction(section: section, label: Self.quickActionLabel(for: section)) { openSection(section) }
                    .accessibilityIdentifier("menuBar.action.\(String(describing: section))")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
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
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Quit VaderCleaner (⌘Q)")
        }
        // Chrome, not content: a step smaller than the readings above.
        .font(.caption)
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Navigation helpers

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
/// File-level so the panel and its tiles share one mapping.
private func swiftUIColor(for status: StatusColor) -> Color {
    switch status {
    case .green: return .green
    case .yellow: return .yellow
    case .red: return .red
    case .gray: return .gray
    }
}

/// One live reading: a small labelled icon, the reading in large type, and a
/// fill bar or caption beneath. Neutral while the reading is fine; tinted in
/// the reading's status colour when it is not. The tile body is its own
/// button (a sibling of the optional corner control, never its ancestor) so
/// each control resolves clicks cleanly.
private struct ReadingTile<Accessory: View>: View {

    /// What sits under the reading: a capacity bar or a line of text.
    enum Footer {
        case bar(Double)
        case caption(String)
    }

    let icon: String
    let iconTint: Color
    let title: String
    /// Plain-language reading, e.g. "679 GB free", "Normal", "23%".
    let value: String
    let footer: Footer
    /// Status colour when the reading is off; `nil` keeps the tile neutral.
    let highlight: Color?
    /// Deep link into the section that owns this reading, or `nil` when there
    /// is none to open.
    let open: (() -> Void)?
    let helpText: String
    /// Optional corner control that acts right in the panel (memory purge,
    /// speed test).
    @ViewBuilder let accessory: () -> Accessory

    @State private var hovered = false

    init(
        icon: String,
        iconTint: Color,
        title: String,
        value: String,
        footer: Footer,
        highlight: Color?,
        open: (() -> Void)?,
        helpText: String,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.value = value
        self.footer = footer
        self.highlight = highlight
        self.open = open
        self.helpText = helpText
        self.accessory = accessory
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // A tile with nowhere to open is plain content rather than a
            // disabled button, which would dim its reading.
            if let open {
                Button(action: open) { content }
                    .buttonStyle(.plain)
                    .help(helpText)
            } else {
                content
                    .help(helpText)
            }
            accessory()
                .padding(.top, 5)
                .padding(.trailing, 6)
        }
        .background(background, in: .rect(cornerRadius: 12))
        .onHover { hovered = $0 && open != nil }
        .animation(VaderMotion.hover, value: hovered)
    }

    private var background: Color {
        if let highlight { return highlight.opacity(hovered ? 0.2 : 0.14) }
        return .white.opacity(hovered ? 0.09 : 0.05)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(iconTint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // No scale factor: a squeezed pass would shrink the text and the
            // smaller size tends to stick, so the reading truncates instead.
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                // Live values roll to their next reading instead of blinking
                // on the refresh.
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(VaderMotion.telemetry, value: value)
            footerView
                // One fixed slot so bar tiles and caption tiles share a height.
                .frame(height: 14)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footerView: some View {
        switch footer {
        case .bar(let fraction):
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(highlight ?? .white.opacity(0.55))
                        .frame(width: proxy.size.width * max(0, min(1, fraction)))
                }
            }
            .frame(height: 4)
            .animation(VaderMotion.telemetry, value: fraction)
            .accessibilityHidden(true)
        case .caption(let text):
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

extension ReadingTile where Accessory == EmptyView {
    /// A tile with no corner control.
    init(
        icon: String,
        iconTint: Color,
        title: String,
        value: String,
        footer: Footer,
        highlight: Color?,
        open: (() -> Void)?,
        helpText: String
    ) {
        self.init(
            icon: icon,
            iconTint: iconTint,
            title: title,
            value: value,
            footer: footer,
            highlight: highlight,
            open: open,
            helpText: helpText,
            accessory: { EmptyView() }
        )
    }
}

/// One verb shortcut: the section's SF Symbol in its own hue over a short
/// action label, deep-linking into that section. Brightens under the pointer
/// like the panel's other surfaces.
private struct QuickAction: View {
    let section: NavigationSection
    let label: String
    let open: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 4) {
                Image(systemName: section.icon)
                    .font(.callout)
                    .foregroundStyle(section.iconAccent)
                    // A fixed glyph box keeps every label on one baseline
                    // whatever the symbol's own height.
                    .frame(height: 18)
                // Fixed size, no scale factor: scaled text tends to stick at
                // the smaller size after any squeezed layout pass.
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(.white.opacity(hovered ? 0.08 : 0), in: .rect(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(VaderMotion.hover, value: hovered)
        .help(section.title)
    }
}

/// Caption-weight link used for inline tile actions ("Free Memory", "Test
/// Speed"): underlines under the pointer and pads its hit target beyond the
/// bare text.
private struct MenuActionLink: View {
    let label: String
    var color: Color?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.semibold))
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
            settings: SmartScanSettingsStore(defaults: previewDefaults),
            statsService: SystemStatsService(autostart: false)
        ))
        .environment(MenuRouter())
}
