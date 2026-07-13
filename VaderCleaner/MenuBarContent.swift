// MenuBarContent.swift
// The menu bar panel — a plain-language health hero with an animated verdict ring, one Next Step action card, a vitals checklist, section chips, and a footer, driven by MenuBarViewModel / SystemStatsService.

import SwiftUI
import AppKit

/// Panel presented when the user clicks the menu bar icon. Built around a
/// three-beat hierarchy an ordinary person can read in two seconds:
///
///   1. **Glance** — a hero with a large animated verdict ring and a
///      plain-language headline ("Your Mac is in good shape").
///   2. **Act** — a single Next Step card carrying the one action the panel
///      recommends right now (review threats, clean up, free memory, or run
///      a Smart Scan), replaced by a live progress strip while a scan runs.
///   3. **Dive** — a vitals checklist (Protection, Storage, Memory, CPU,
///      Wi-Fi + connected devices) whose rows deep-link into their
///      sections, four quiet section chips, and a footer.
///
/// Values refresh on the same 2-second cadence as the Health Monitor.
struct MenuBarContent: View {

    @Environment(MenuBarViewModel.self) private var menuBar
    @Environment(ConnectedDevicesMonitor.self) private var connectedDevices
    @Environment(MalwareViewModel.self) private var malware
    @Environment(SmartScanViewModel.self) private var smartScan
    @Environment(MenuRouter.self) private var menuRouter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hover state for the hero deep-link surface.
    @State private var heroHovered = false

    /// The verdict ring's animated fill. Starts empty and sweeps to the live
    /// score on open — the panel's signature entrance — then glides between
    /// readings on the telemetry cadence.
    @State private var ringScore: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 10) {
                actionCard
                vitalsCard
                sectionChips
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 380)
        .background(panelBackground)
        // Shared Health Monitor blue for every tinted control; semantic status
        // colors (verdict, pressure, protection) stay as-is so they keep
        // conveying meaning.
        .tint(healthAccent)
        // Refresh the device list each time the panel opens — devices change
        // infrequently, so an on-open read beats a dedicated poll timer.
        .task { connectedDevices.refresh() }
    }

    // MARK: - Theme

    /// The panel shares the Health Monitor section's colour identity so the
    /// popup and the in-app section read as one product.
    private var healthTheme: SectionTheme { NavigationSection.healthMonitor.theme }
    private var healthAccent: Color { healthTheme.accent }

    /// One continuous gradient behind the whole panel, with the accent
    /// blooming down from behind the hero ring.
    private var panelBackground: some View {
        ZStack {
            LinearGradient(
                colors: [healthTheme.backdropTop, healthTheme.backdropBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [healthAccent.opacity(0.28), .clear],
                center: UnitPoint(x: 0.5, y: 0.05),
                startRadius: 8,
                endRadius: 260
            )
        }
    }

    // MARK: - Hero

    /// The verdict the hero renders: the shared derivation capped at Good
    /// until a first scan exists, so the headline never claims "at its best"
    /// directly above a first-scan invitation.
    private var displayedHealth: MacHealthStatus? {
        MenuBarViewModel.displayedHealth(menuBar.macHealth, hasScanned: malware.lastScanDate != nil)
    }

    /// The verdict's signature colour (gray while still measuring).
    private var verdictColor: Color { displayedHealth?.accentColor ?? Color(white: 0.6) }

    /// Glance zone: a large animated verdict ring over a plain-language
    /// headline and the device line. The whole hero deep-links into the
    /// Health Monitor.
    private var hero: some View {
        Button {
            openSection(.healthMonitor)
        } label: {
            VStack(spacing: 10) {
                verdictRing
                VStack(spacing: 3) {
                    Text(MenuBarViewModel.heroHeadline(for: displayedHealth))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 5) {
                        Text("\(menuBar.deviceName) · \(menuBar.systemUptimeString)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                        // Chevron affordance: the hero deep-links, and
                        // brightens under the pointer.
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(heroHovered ? 0.8 : 0.35))
                    }
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .overlay(Color.white.opacity(heroHovered ? 0.04 : 0).allowsHitTesting(false))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .onHover { heroHovered = $0 }
        .animation(VaderMotion.hover, value: heroHovered)
        .help("Open Health Monitor")
    }

    /// The hero ring: a soft glow, a faint track, and an arc that sweeps in
    /// on open to `MacHealthStatus.score` in the verdict's colour — the
    /// verdict as a shape as well as a sentence. A bare track while still
    /// measuring. The app's health-pulse glyph sits at the centre, matching
    /// the menu bar icon the user just clicked.
    private var verdictRing: some View {
        ZStack {
            // Static soft glow in the verdict colour; not animated, so the
            // blur renders once rather than per frame.
            Circle()
                .fill(verdictColor.opacity(0.3))
                .frame(width: 58, height: 58)
                .blur(radius: 18)
            Circle()
                .stroke(.white.opacity(0.13), lineWidth: 6)
            Circle()
                .trim(from: 0, to: ringScore)
                .stroke(
                    AngularGradient(
                        colors: [verdictColor.opacity(0.55), verdictColor],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * ringScore)
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: 76, height: 76)
        .onAppear {
            let target = displayedHealth?.score ?? 0
            if reduceMotion {
                ringScore = target
            } else {
                withAnimation(.smooth(duration: 0.9)) { ringScore = target }
            }
        }
        .onChange(of: displayedHealth?.score) { _, newScore in
            withAnimation(VaderMotion.telemetry) { ringScore = newScore ?? 0 }
        }
        // The ring is decorative alongside the headline; VoiceOver reads the
        // hero's words instead of a second copy of the same fact.
        .accessibilityHidden(true)
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

    // MARK: - Next Step card

    /// The panel's one recommended action, or `nil` while a scan runs (the
    /// card narrates the scan instead).
    private var nextStep: MenuBarViewModel.NextStep? {
        MenuBarViewModel.nextStep(
            protection: protectionStatus,
            disk: menuBar.diskStats,
            pressure: menuBar.ramPressureLevel,
            lastScanDate: malware.lastScanDate
        )
    }

    /// Act zone: exactly one card. While a scan runs it narrates the scan;
    /// otherwise it carries the single next best step.
    @ViewBuilder
    private var actionCard: some View {
        if let scanActivity {
            scanningStrip(scanActivity)
        } else if let nextStep {
            nextStepCard(nextStep)
        }
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
                    .font(.title2)
                    .foregroundStyle(healthAccent)
                    // Motion as meaning: the shield breathes only while a
                    // scan is actually running.
                    .symbolEffect(.pulse, isActive: true)
                VStack(alignment: .leading, spacing: 3) {
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
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(activity == .threatScan ? "Open Protection" : "Open Smart Scan")
    }

    /// The step's signature colour: red for threats, orange for the other
    /// urgent conditions, green for the all-clear, and the panel accent for
    /// plain suggestions.
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
        case .cleanup:     return "trash.fill"
        case .performance: return "memorychip"
        case .smartScan:   return step.urgency == .allClear ? "checkmark.seal.fill" : "sparkles"
        }
    }

    /// The Next Step card: an icon badge in the step's colour, the title and
    /// detail in plain language, and one full-width action button.
    private func nextStepCard(_ step: MenuBarViewModel.NextStep) -> some View {
        let color = stepColor(step)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: stepIcon(step))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(color.opacity(0.16), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                open(step)
            } label: {
                Text(step.actionLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.vaderProminent)
            // The prominent style fills with the section accent from the
            // environment; hand it the step's colour so urgency reads in the
            // button itself.
            .environment(\.sectionAccent, color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
    }

    /// Maps the view-model's framework-free step target onto the app's
    /// navigation sections and deep-links there.
    private func open(_ step: MenuBarViewModel.NextStep) {
        let section: NavigationSection
        switch step.target {
        case .smartScan:   section = .smartScan
        case .cleanup:     section = .systemJunk
        case .performance: section = .performance
        case .threats:     section = .malwareRemoval
        }
        openSection(section, startScan: step.startsScan)
    }

    // MARK: - Vitals checklist

    /// Status dot for the Protection row, or `nil` mid-scan (the action card
    /// is already narrating the activity).
    private var protectionDot: StatusColor? {
        switch protectionStatus {
        case .protected:    return .green
        case .threatsFound: return .red
        case .notScanned:   return .gray
        case .scanning:     return nil
        }
    }

    /// Dive zone: one card of scannable rows — icon chip in the destination
    /// section's hue, plain value, status dot, chevron. Rows deep-link; the
    /// inline links are reserved for actions that finish right in the panel
    /// (memory purge, speed test, eject).
    private var vitalsCard: some View {
        VStack(spacing: 0) {
            VitalRow(
                icon: "shield.lefthalf.filled",
                iconTint: NavigationSection.malwareRemoval.iconAccent,
                title: String(localized: "Protection"),
                value: MenuBarViewModel.protectionStatusLabel(protectionStatus),
                status: protectionDot,
                open: { openSection(.malwareRemoval) },
                helpText: String(localized: "Open Protection")
            )
            rowDivider
            VitalRow(
                icon: "internaldrive",
                iconTint: NavigationSection.systemJunk.iconAccent,
                title: String(localized: "Storage"),
                value: storageValue,
                status: MenuBarViewModel.diskStatusColor(menuBar.diskStats),
                open: { openSection(.systemJunk) },
                helpText: String(localized: "Open Cleanup")
            )
            rowDivider
            VitalRow(
                icon: "memorychip",
                iconTint: NavigationSection.performance.iconAccent,
                title: String(localized: "Memory"),
                value: menuBar.ramPressureLabel,
                status: menuBar.ramPressureColor,
                inlineControl: { AnyView(memoryFlushControl) },
                open: { openSection(.performance) },
                helpText: String(localized: "Open Performance")
            )
            rowDivider
            VitalRow(
                icon: "cpu",
                iconTint: healthAccent,
                title: String(localized: "CPU"),
                value: cpuValue,
                status: menuBar.cpuLoadColor,
                open: { openSection(.healthMonitor) },
                helpText: String(localized: "Open Health Monitor")
            )
            rowDivider
            networkRow
            devicesRows
        }
        .padding(.vertical, 2)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
    }

    private var rowDivider: some View {
        Divider()
            .overlay(.white.opacity(0.06))
            .padding(.leading, 46)
    }

    /// "679 GB free" — free space is the number an ordinary person actually
    /// wants; the volume name rides in the row's tooltip.
    private var storageValue: String {
        let format = String(
            localized: "%@ free",
            comment: "Storage row value; %@ is the free-space amount."
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

    /// The Memory row's inline action: purges inactive RAM through the
    /// privileged helper right from the panel — no main-window round trip —
    /// with a spinner in flight, a confirmation once done (clickable to purge
    /// again), and an orange retry after a failure.
    @ViewBuilder
    private var memoryFlushControl: some View {
        switch menuBar.memoryFlushState {
        case .running:
            ProgressView().controlSize(.small)
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

    // MARK: - Network + devices

    /// The Wi-Fi row: two lines rather than one. The first carries the title,
    /// the SSID, and the in-panel speed test; the throughput pair gets its own
    /// line below, so the tick-updating readings can never squeeze the title
    /// (only the SSID ever truncates). Not a deep link — there is no network
    /// section to open.
    private var networkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VitalRow.iconChip(icon: "wifi", tint: NavigationSection.spaceLens.iconAccent)
                Text("Wi-Fi")
                    .font(.subheadline.weight(.semibold))
                    .layoutPriority(1)
                Text(menuBar.wifiNetworkName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                speedTestControl
                    .layoutPriority(1)
            }
            HStack(spacing: 12) {
                throughputReading(symbol: "arrow.down", value: menuBar.networkDownString)
                throughputReading(symbol: "arrow.up", value: menuBar.networkUpString)
                Spacer(minLength: 0)
            }
            // Aligns the readings with the title text (chip width + spacing).
            .padding(.leading, 36)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func throughputReading(symbol: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(VaderMotion.telemetry, value: value)
                // Reserve room for a three-digit rate ("999 KB/s") so the
                // row doesn't reflow every time the reading changes width
                // on the 2-second refresh.
                .frame(minWidth: 58, alignment: .leading)
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

    /// Connected devices ride under the Wi-Fi row as compact sub-rows —
    /// both are "what's attached to this Mac" facts. At most three, with an
    /// explicit overflow line so the list never truncates silently.
    @ViewBuilder
    private var devicesRows: some View {
        if !connectedDevices.devices.isEmpty {
            let shown = connectedDevices.devices.prefix(3)
            VStack(alignment: .leading, spacing: 6) {
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
            .padding(.leading, 46)
            .padding(.trailing, 12)
            .padding(.bottom, 9)
        }
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

    // MARK: - Section chips

    /// The sections the cards above don't already cover, as four quiet chips
    /// — the rest of the app stays one click away without a wall of icons.
    /// Order follows the rail.
    private static let chipSections: [NavigationSection] = [
        .smartScan, .largeOldFiles, .applications, .spaceLens
    ]

    private var sectionChips: some View {
        HStack(spacing: 6) {
            ForEach(Self.chipSections) { section in
                SectionChip(section: section) { openSection(section) }
            }
        }
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
/// File-level so the panel and its private rows share one mapping.
private func swiftUIColor(for status: StatusColor) -> Color {
    switch status {
    case .green: return .green
    case .yellow: return .yellow
    case .red: return .red
    case .gray: return .gray
    }
}

/// One vitals row: an icon chip in the destination section's hue, the vital's
/// name, an optional inline control, a plain-language value with a status
/// dot, and a chevron. The informational area is its own button (sibling of
/// the inline control, never its ancestor) so each control resolves clicks
/// cleanly.
private struct VitalRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    /// Plain-language reading, e.g. "679 GB free", "Normal", "23%".
    let value: String
    var status: StatusColor?
    /// Optional trailing control that acts right in the panel (memory purge).
    var inlineControl: (() -> AnyView)?
    /// Whole-row deep link into the section that owns this reading.
    let open: () -> Void
    let helpText: String

    @State private var hovered = false

    var body: some View {
        // Two sibling deep-link buttons flank the optional inline control so
        // the control can sit between the name and the reading (never past
        // the chevron) while every control still resolves clicks cleanly.
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Self.iconChip(icon: icon, tint: iconTint)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            if let inlineControl {
                inlineControl()
            }
            Button(action: open) {
                HStack(spacing: 8) {
                    // No scale factor: a squeezed pass would shrink the text
                    // and the smaller size tends to stick, so the reading
                    // keeps its size and the row title truncates instead
                    // (see the outer button's layout priority).
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        // Live values roll to their next reading instead of
                        // blinking on the 2-second refresh.
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(VaderMotion.telemetry, value: value)
                    if let status {
                        Circle()
                            .fill(swiftUIColor(for: status))
                            .frame(width: 7, height: 7)
                            // The dot is color-only; VoiceOver speaks its
                            // meaning instead.
                            .accessibilityLabel(MenuBarViewModel.statusAccessibilityLabel(for: status))
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(hovered ? 0.7 : 0.3))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            // The reading side wins the width contest so tick updates never
            // compress (and rescale) the value text.
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(hovered ? 0.05 : 0))
        .onHover { hovered = $0 }
        .animation(VaderMotion.hover, value: hovered)
    }

    /// The 26pt rounded icon chip shared by the vitals rows and the Wi-Fi
    /// row: the section hue as a soft fill under its glyph, quietly teaching
    /// the app's colour map.
    static func iconChip(icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 7))
    }
}

/// One quiet section chip: the section's SF Symbol in its own hue over a
/// short label, deep-linking into that section. Brightens under the pointer
/// like the panel's other surfaces.
private struct SectionChip: View {
    let section: NavigationSection
    let open: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 4) {
                Image(systemName: section.icon)
                    .font(.callout)
                    .foregroundStyle(section.iconAccent)
                // Fixed size, no scale factor: scaled text tends to stick at
                // the smaller size after any squeezed layout pass, making the
                // chips' labels drift between renders.
                Text(section.title)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .background(.white.opacity(hovered ? 0.1 : 0.05), in: .rect(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(VaderMotion.hover, value: hovered)
        .help(section.title)
    }
}

/// Caption-weight link used for inline row actions ("Free Memory", "Test
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
