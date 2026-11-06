// MenuBarContent.swift
// The menu bar panel, built as a glance — a verdict ring, three readings, and one button — driven by MenuBarViewModel / SystemStatsService.

import SwiftUI
import AppKit
import VaderCleanerCore

/// Panel presented when the user clicks the menu bar icon. It answers one
/// question — "is my Mac OK?" — in a second, then offers exactly one thing to
/// do about it:
///
///   1. **Verdict** — a ring that fills with the Mac's health and drains when
///      something is wrong, a plain-language headline ("Your Mac is in good
///      shape", "2 things need attention"), and one line of facts
///      ("Protected · Last scan 2 days ago"), or the live tally while a scan
///      runs.
///   2. **Readings** — free storage, memory pressure, and CPU load as three
///      numbers. A number is coloured only when it is the subject of an
///      issue, so the readings can't contradict the verdict.
///   3. **One button** — the fix for the worst issue (critical memory is
///      purged right here), the running scan, or a scan. Quiet glass when
///      nothing is wrong. Any further issues sit beneath it as small links.
///
/// Values refresh on the same cadence as the Health Monitor.
struct MenuBarContent: View {

    @Environment(MenuBarViewModel.self) private var menuBar
    @Environment(PreferencesStore.self) private var preferences
    @Environment(SystemStatsService.self) private var systemStats
    @Environment(MalwareViewModel.self) private var malware
    @Environment(SmartScanViewModel.self) private var smartScan
    @Environment(MenuRouter.self) private var menuRouter
    @Environment(\.openWindow) private var openWindow

    /// Hover state for the verdict's deep-link surface.
    @State private var verdictHovered = false

    var body: some View {
        VStack(spacing: 0) {
            verdictArea
            VStack(spacing: 14) {
                readings
                primaryButton
                otherIssues
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            Divider()
            footer
        }
        .frame(width: 320)
        .background(panelBackground)
        // Shared Health Monitor blue for every tinted control; semantic status
        // colors (verdict, issues, readings) stay as-is so they keep
        // conveying meaning.
        .tint(healthAccent)
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
    /// blooming down from behind the ring.
    private var panelBackground: some View {
        ZStack {
            LinearGradient(
                colors: [healthTheme.backdropTop, healthTheme.backdropBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [toneColor(verdict.tone).opacity(0.18), .clear],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 8,
                endRadius: 220
            )
            .animation(VaderMotion.telemetry, value: verdict.tone)
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

    // MARK: - Verdict

    /// The disk-and-battery verdict, capped at Good until a first scan exists.
    private var health: MacHealthStatus? {
        MenuBarViewModel.displayedHealth(menuBar.macHealth, hasScanned: malware.lastScanDate != nil)
    }

    /// The health verdict folded together with the attention list so the
    /// panel never praises a Mac above a threat.
    private var verdict: MenuBarViewModel.PanelVerdict {
        MenuBarViewModel.panelVerdict(health: health, attention: attention)
    }

    /// The facts under the headline, or the scan's own narration while one
    /// runs.
    private var verdictDetail: String {
        if let scanActivity {
            return MenuBarViewModel.scanningDetail(for: scanActivity, itemsScanned: smartScan.scannedItemCount)
        }
        return MenuBarViewModel.panelDetail(
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

    /// The ring, headline, and facts, centred. The whole area deep-links into
    /// the Health Monitor; the Mac's name and uptime ride in its tooltip.
    private var verdictArea: some View {
        Button {
            openSection(.healthMonitor)
        } label: {
            VStack(spacing: 10) {
                VerdictRing(
                    fraction: MenuBarViewModel.ringFraction(health: health, attention: attention),
                    tone: verdict.tone,
                    color: toneColor(verdict.tone),
                    isScanning: scanActivity != nil
                )
                VStack(spacing: 3) {
                    Text(verdict.headline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(verdictDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        // The live item tally rolls instead of blinking as a
                        // scan reports progress.
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(VaderMotion.telemetry, value: verdictDetail)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(verdictHovered ? 0.04 : 0).allowsHitTesting(false))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .onHover { verdictHovered = $0 }
        .animation(VaderMotion.hover, value: verdictHovered)
        .help("\(menuBar.deviceName) · \(menuBar.systemUptimeString) — Open Health Monitor")
        .accessibilityIdentifier("menuBar.verdict")
    }

    // MARK: - Readings

    /// The readings the user has left switched on, side by side.
    @ViewBuilder
    private var readings: some View {
        let shown = visibleReadings
        if !shown.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, reading in
                    if index > 0 {
                        Divider()
                            .frame(height: 30)
                            .opacity(0.5)
                    }
                    readingCell(reading)
                }
            }
            .padding(.vertical, 6)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
        }
    }

    private var visibleReadings: [MenuBarViewModel.Reading] {
        var shown: [MenuBarViewModel.Reading] = []
        if preferences.isPanelRowEnabled(.storage) { shown.append(.storage) }
        if preferences.isPanelRowEnabled(.memory) { shown.append(.memory) }
        if preferences.isPanelRowEnabled(.cpu) { shown.append(.cpu) }
        return shown
    }

    @ViewBuilder
    private func readingCell(_ reading: MenuBarViewModel.Reading) -> some View {
        let emphasis: Color? = MenuBarViewModel.readingNeedsAttention(reading, attention: attention) ? .orange : nil
        switch reading {
        case .storage:
            ReadingCell(
                value: menuBar.availableDiskSpace,
                label: String(localized: "free", comment: "Caption under the free-storage reading."),
                emphasis: emphasis,
                helpText: String(localized: "Open Cleanup")
            ) { openSection(.systemJunk) }
            .accessibilityIdentifier("menuBar.reading.storage")
        case .memory:
            ReadingCell(
                value: menuBar.ramPressureLabel,
                label: String(localized: "memory", comment: "Caption under the memory-pressure reading."),
                emphasis: emphasis,
                helpText: String(localized: "Open Performance")
            ) { openSection(.performance) }
            .accessibilityIdentifier("menuBar.reading.memory")
        case .cpu:
            ReadingCell(
                value: menuBar.formattedCPU,
                label: String(localized: "CPU", comment: "Caption under the CPU-load reading."),
                emphasis: emphasis,
                helpText: cpuHelp
            ) { openSection(.healthMonitor) }
            .accessibilityIdentifier("menuBar.reading.cpu")
        }
    }

    /// The CPU temperature, when the SMC reports one, rides in the tooltip
    /// rather than crowding the number.
    private var cpuHelp: String {
        guard let temp = menuBar.cpuTemperature else { return String(localized: "Open Health Monitor") }
        return "\(temp) — " + String(localized: "Open Health Monitor")
    }

    // MARK: - Primary button

    private var primaryAction: MenuBarViewModel.PrimaryAction {
        MenuBarViewModel.primaryAction(
            protection: protectionStatus,
            scanActivity: scanActivity,
            disk: menuBar.diskStats,
            pressure: menuBar.ramPressureLevel,
            lastScanDate: malware.lastScanDate,
            flushState: menuBar.memoryFlushState
        )
    }

    /// The panel's one button. Urgent fixes fill in the alert colour, a
    /// suggestion in the accent, and the all-clear and a running scan are
    /// quiet glass.
    @ViewBuilder
    private var primaryButton: some View {
        let action = primaryAction
        let label = HStack(spacing: 8) {
            if action.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            Text(action.label)
        }
        switch action.style {
        case .urgent, .suggested:
            Button { perform(action.kind) } label: { label }
                .buttonStyle(.vaderProminent)
                // The prominent style fills with the section accent from the
                // environment; hand it the action's colour so urgency reads in
                // the button itself.
                .environment(\.sectionAccent, buttonColor(for: action))
                .controlSize(.large)
                .accessibilityIdentifier("menuBar.primaryAction")
        case .quiet:
            Button { perform(action.kind) } label: { label }
                .buttonStyle(.vaderGlass)
                .controlSize(.large)
                .accessibilityIdentifier("menuBar.primaryAction")
        }
    }

    private func buttonColor(for action: MenuBarViewModel.PrimaryAction) -> Color {
        switch action.style {
        case .urgent:
            if case .open(.threats, _) = action.kind { return .red }
            return .orange
        case .suggested, .quiet:
            return healthAccent
        }
    }

    // MARK: - Other issues

    /// Issues behind the worst one, as quiet links, so fixing one never
    /// reveals another that was hidden.
    @ViewBuilder
    private var otherIssues: some View {
        let rest = attention.dropFirst()
        if !rest.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(rest), id: \.target) { step in
                    IssueLink(step: step, color: step.target == .threats ? .red : .orange) {
                        perform(step)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("menuBar.otherIssues")
        }
    }

    // MARK: - Actions

    private func perform(_ kind: MenuBarViewModel.PrimaryAction.Kind) {
        switch kind {
        case .open(let target, let startsScan):
            openSection(Self.section(for: target), startScan: startsScan)
        case .flushMemory:
            Task { await menuBar.flushMemory() }
        case .showScan(let activity):
            openSection(activity == .threatScan ? .malwareRemoval : .smartScan)
        }
    }

    /// A step's fix: critical memory is purged in place, anything else opens
    /// the section that owns it.
    private func perform(_ step: MenuBarViewModel.NextStep) {
        if step.target == .performance {
            perform(.flushMemory)
        } else {
            perform(.open(step.target, startsScan: step.startsScan))
        }
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

/// The verdict as a shape: a ring that fills with the Mac's health in the
/// verdict's colour, with the verdict's symbol at its centre — a spinner
/// while the first reading is measured, and a breathing shield while a scan
/// runs.
private struct VerdictRing: View {
    let fraction: Double
    let tone: MenuBarViewModel.PanelVerdict.Tone
    let color: Color
    let isScanning: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.1), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            centre
        }
        .frame(width: 84, height: 84)
        .animation(VaderMotion.telemetry, value: fraction)
        .animation(VaderMotion.telemetry, value: tone)
        // Decorative beside the headline; VoiceOver reads the words.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var centre: some View {
        if isScanning {
            Image(systemName: "shield")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(color)
                // Motion as meaning: the shield breathes only while a scan
                // is actually running.
                .symbolEffect(.pulse, isActive: true)
        } else {
            switch tone {
            case .measuring:
                ProgressView().controlSize(.small)
            case .good:
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(color)
            case .caution:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(color)
            case .alert:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
    }
}

/// One reading: the number in large rounded type over a one-word caption,
/// deep-linking into the section that owns it. Coloured only when it is the
/// subject of an issue.
private struct ReadingCell: View {
    let value: String
    let label: String
    let emphasis: Color?
    let helpText: String
    let open: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 2) {
                // No scale factor: a squeezed pass would shrink the text and
                // the smaller size tends to stick, so the reading truncates
                // instead.
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(emphasis ?? .white)
                    .lineLimit(1)
                    // Live values roll to their next reading instead of
                    // blinking on the refresh.
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(VaderMotion.telemetry, value: value)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(hovered ? 0.06 : 0), in: .rect(cornerRadius: 8))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovered = $0 }
        .animation(VaderMotion.hover, value: hovered)
        .help(helpText)
    }
}

/// A further issue beneath the button: a coloured dot, its title, and a
/// chevron, in caption weight so it never competes with the primary fix.
private struct IssueLink: View {
    let step: MenuBarViewModel.NextStep
    let color: Color
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(step.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(step.actionLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(hovered ? 0.8 : 0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(hovered ? 0.08 : 0.04), in: .rect(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(VaderMotion.hover, value: hovered)
        .help(step.detail)
    }
}

#Preview {
    let previewDefaults = UserDefaults(suiteName: "menu-preview")!
    let prefs = PreferencesStore(defaults: previewDefaults)
    return MenuBarContent()
        .environment(MenuBarViewModel(service: SystemStatsService(autostart: false)))
        .environment(prefs)
        .environment(SystemStatsService(autostart: false))
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
