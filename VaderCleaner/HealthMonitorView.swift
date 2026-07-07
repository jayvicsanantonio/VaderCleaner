// HealthMonitorView.swift
// Health Monitor dashboard — a tall Mac Health hero and a Disk Encryption card in the left column, with a grid of live metric cards (Battery, Disk Health, RAM, CPU, Disk Space) on the right, bound to SystemStatsService via HealthMonitorViewModel.

import SwiftUI

/// Two-column dashboard of live system health. The left column leads with the
/// `MacHealthHero` — one overall verdict, a glowing ring, and the boot volume's
/// fill — and carries the Disk Encryption card beneath it. The right column is a
/// reflowing grid of `HealthCard` tiles, each with a prominent icon, an info
/// affordance, a primary value, and a status dot driven by the view-model's
/// `StatusColor`.
///
/// The right grid uses `LazyVGrid` with `.adaptive(minimum: 240)` so it drops
/// from two columns to one as the window narrows, while the left column keeps a
/// fixed width so the hero never collapses.
struct HealthMonitorView: View {

    @State private var viewModel: HealthMonitorViewModel

    init(service: SystemStatsService) {
        _viewModel = State(initialValue: HealthMonitorViewModel(service: service))
    }

    /// Fixed width of the left hero column, so the hero and its disk bar keep a
    /// stable shape while the right tiles absorb the remaining width.
    private let leftColumnWidth: CGFloat = 340

    /// The section's blue accent — the Mac Health chrome color used for the
    /// ring, verdict, status badges, and progress bars.
    private let sectionAccent = NavigationSection.healthMonitor.theme.accent

    /// Icon-tile tint for the metric cards — the pink Mac Health hero family,
    /// shared with the rail's active state via `iconAccent` so both read as one
    /// identity. Only the rounded icon glyphs use this; everything else stays on
    /// `sectionAccent`.
    private let heroTint = NavigationSection.healthMonitor.iconAccent

    /// The overall Mac Health verdict color (gray while measuring). Drives the
    /// status dots and progress bars so they track the Mac's health at a glance.
    private var verdictAccent: Color {
        viewModel.macHealth?.accentColor ?? Color(white: 0.55)
    }

    /// Drives the one-shot staggered entrance of the metric tiles when the
    /// dashboard first appears, mirroring the Smart Scan results grid.
    @State private var appeared = false

    /// Per-metric health color for the Battery card — the battery's own
    /// traffic-light verdict rather than the overall Mac Health tint, so the
    /// tile's dot and gauge read that metric specifically.
    private var batteryHealthColor: Color {
        Self.color(for: HealthMonitorViewModel.batteryColor(for: viewModel.batteryAvailability))
    }

    /// Per-metric health color for the Disk Health card — the drive's own SMART
    /// verdict, independent of the overall Mac Health tint.
    private var smartHealthColor: Color {
        Self.color(for: HealthMonitorViewModel.smartColor(for: viewModel.smartStatus))
    }

    /// Per-metric health color for the Memory card, from the current
    /// memory-pressure level rather than the overall verdict.
    private var ramHealthColor: Color {
        Self.color(for: HealthMonitorViewModel.pressureColor(for: viewModel.ramPressureLevel))
    }

    /// Per-metric health color for the CPU card, from the current load.
    private var cpuHealthColor: Color {
        Self.color(for: HealthMonitorViewModel.cpuColor(for: viewModel.service.cpuUsage))
    }

    /// Per-metric health color for the Disk Space card, from current fullness.
    private var diskHealthColor: Color {
        Self.color(for: HealthMonitorViewModel.diskColor(for: viewModel.service.diskSpace))
    }

    /// Per-metric health color for the Disk Encryption card, so its dot tracks
    /// FileVault's own state rather than the overall verdict.
    private var fileVaultHealthColor: Color {
        Self.color(for: HealthMonitorViewModel.fileVaultColor(for: viewModel.fileVaultState))
    }

    /// Live memory fullness as a rounded percentage for the Memory ring's eye.
    private var ramUsagePercent: String {
        Self.percentString(HealthMonitorViewModel.ramUsageRatio(viewModel.service.ramUsage))
    }

    /// Live disk fullness as a rounded percentage for the Disk Space ring's eye.
    private var diskUsagePercent: String {
        Self.percentString(viewModel.diskRatio)
    }

    /// Formats a unit-interval ratio as an integer percentage (e.g. `0.58` →
    /// `"58%"`) for a gauge's center label.
    private static func percentString(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    /// The hero's system snapshot: device and OS context that appears nowhere
    /// else on the dashboard, so the hero carries information the metric tiles
    /// don't repeat. The chip row is omitted when the name can't be read.
    private var systemDetails: [MacHealthDetail] {
        var rows: [MacHealthDetail] = []
        if !viewModel.chipName.isEmpty {
            rows.append(MacHealthDetail(
                icon: "cpu",
                title: String(localized: "Chip"),
                value: viewModel.chipName
            ))
        }
        rows.append(MacHealthDetail(
            icon: "apple.logo",
            title: String(localized: "macOS"),
            value: viewModel.osVersion
        ))
        rows.append(MacHealthDetail(
            icon: "clock",
            title: String(localized: "Uptime"),
            value: viewModel.uptime
        ))
        return rows
    }

    /// Maps the view-model's framework-free `StatusColor` to a softened SwiftUI
    /// color tuned for the dark glass tiles — the same warm-to-cool ramp the
    /// Mac Health verdict uses, so a green battery and a green verdict read in
    /// the same hue family.
    private static func color(for status: StatusColor) -> Color {
        switch status {
        case .green:  return Color(red: 0.40, green: 0.85, blue: 0.66)
        case .yellow: return Color(red: 0.99, green: 0.78, blue: 0.34)
        case .red:    return Color(red: 1.00, green: 0.45, blue: 0.38)
        case .gray:   return Color(white: 0.55)
        }
    }

    /// SF Symbol shown in the Disk Health badge, chosen by the SMART verdict so
    /// the glyph itself signals the state — a sealed shield when healthy, a
    /// warning shield when failing, an indeterminate mark when unreadable.
    private var smartBadgeSymbol: String {
        switch viewModel.smartStatus {
        case .good:    return "checkmark.shield.fill"
        case .failing: return "exclamationmark.shield.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var body: some View {
        // The whole dashboard fills the detail pane without a scroll view: the
        // left hero stretches to the column height and the right tiles divide
        // the available height into equal rows, so the screen fits any window
        // tall enough for the navigation rail.
        HStack(alignment: .top, spacing: 20) {
            // Left column: the focal hero plus the binary security toggle,
            // mirroring the reference dashboard's hero-and-card stack.
            VStack(spacing: 16) {
                MacHealthHero(
                    status: viewModel.macHealth,
                    details: systemDetails,
                    volumeName: viewModel.diskVolumeName,
                    diskUsageDetail: viewModel.diskUsageDetail,
                    diskRatio: viewModel.diskRatio
                )
                .frame(maxHeight: .infinity)
                fileVaultCard
            }
            .frame(width: leftColumnWidth)

            // Right column: the per-metric tiles in two rows of two with the
            // full-width Disk Space tile beneath. Grouped in one container so
            // adjacent glass cards sample each other and refract consistently.
            // Every tile takes an equal share of the column height so the grid
            // never overflows the pane.
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        batteryCard.staggeredEntrance(index: 0, appeared: appeared)
                        smartCard.staggeredEntrance(index: 1, appeared: appeared)
                    }
                    HStack(spacing: 16) {
                        ramCard.staggeredEntrance(index: 2, appeared: appeared)
                        cpuCard.staggeredEntrance(index: 3, appeared: appeared)
                    }
                    diskCard.staggeredEntrance(index: 4, appeared: appeared)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.healthMonitor.title)
        .onAppear { appeared = true }
    }

    // MARK: - Cards

    private var batteryCard: some View {
        HealthCard(
            icon: "battery.100",
            title: "Battery Health",
            accent: sectionAccent,
            iconColor: heroTint,
            statusColor: batteryHealthColor,
            info: "Battery condition and capacity relative to when it was new, plus lifetime charge cycles."
        ) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    switch viewModel.batteryAvailability {
                    case .unknown:
                        Text("—")
                            .font(.title.weight(.semibold))
                        Text("Checking battery")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .absent:
                        Text("—")
                            .font(.title.weight(.semibold))
                        Text("No internal battery")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .present(let stats):
                        Text(HealthMonitorViewModel.batteryCapacityString(stats))
                            .font(.title.weight(.semibold))
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("health.battery.capacity")
                        Text(stats.condition)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("\(stats.cycleCount) cycles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                // The capacity gauge only reads meaningfully for a real battery;
                // desktops and the pre-measurement state omit it.
                if case .present = viewModel.batteryAvailability {
                    HealthGauge(
                        ratio: HealthMonitorViewModel.batteryCapacityRatio(for: viewModel.batteryAvailability),
                        color: batteryHealthColor,
                        centerSymbol: "bolt.fill"
                    )
                    .frame(width: 74, height: 74)
                }
            }
        }
        .accessibilityIdentifier("health.card.battery")
    }

    private var smartCard: some View {
        HealthCard(
            icon: "internaldrive",
            title: "Disk Health",
            accent: sectionAccent,
            iconColor: heroTint,
            statusColor: smartHealthColor,
            info: "The drive's SMART self-assessment. \"Good\" means the disk reports no predicted failures."
        ) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.smartLabel)
                        .font(.title.weight(.semibold))
                        .accessibilityIdentifier("health.smart.label")
                    Text("Drive self-check")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HealthBadge(symbol: smartBadgeSymbol, color: smartHealthColor)
                    .frame(width: 62, height: 62)
            }
        }
        .accessibilityIdentifier("health.card.smart")
    }

    private var ramCard: some View {
        HealthCard(
            icon: "memorychip",
            title: "Memory",
            accent: sectionAccent,
            iconColor: heroTint,
            statusColor: ramHealthColor,
            info: "How much memory your open apps are using right now, with the system's current memory-pressure level."
        ) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.ramUsage)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityIdentifier("health.ram.usage")
                    PressureBadge(label: viewModel.ramPressureLabel, accent: ramHealthColor)
                }
                Spacer(minLength: 8)
                HealthGauge(
                    ratio: HealthMonitorViewModel.ramUsageRatio(viewModel.service.ramUsage),
                    color: ramHealthColor,
                    centerText: ramUsagePercent
                )
                .frame(width: 74, height: 74)
            }
        }
        .accessibilityIdentifier("health.card.ram")
    }

    private var cpuCard: some View {
        HealthCard(
            icon: "cpu",
            title: "CPU",
            accent: sectionAccent,
            iconColor: heroTint,
            statusColor: cpuHealthColor,
            info: "How much of your processor's power is in use right now, across all cores."
        ) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.cpuPercent)
                        .font(.title.weight(.semibold))
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("health.cpu.percent")
                    Text("in use")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HealthGauge(
                    ratio: viewModel.cpuRatio,
                    color: cpuHealthColor,
                    centerText: viewModel.cpuPercent
                )
                .frame(width: 74, height: 74)
            }
        }
        .accessibilityIdentifier("health.card.cpu")
    }

    private var diskCard: some View {
        HealthCard(
            icon: "externaldrive",
            title: "Disk Space",
            accent: sectionAccent,
            iconColor: heroTint,
            statusColor: diskHealthColor,
            info: "How full your startup disk is. Freeing up space keeps your Mac responsive."
        ) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.diskUsage)
                        .font(.title.weight(.semibold))
                        .accessibilityIdentifier("health.disk.usage")
                    ProgressView(value: viewModel.diskRatio)
                        .progressViewStyle(.linear)
                        .tint(diskHealthColor)
                }
                Spacer(minLength: 8)
                HealthGauge(
                    ratio: viewModel.diskRatio,
                    color: diskHealthColor,
                    centerText: diskUsagePercent
                )
                .frame(width: 74, height: 74)
            }
        }
        .accessibilityIdentifier("health.card.disk")
    }

    // MARK: - Disk Encryption card

    /// FileVault — a binary security toggle rather than a continuously varying
    /// reading — gets a horizontal card beneath the hero, echoing the reference
    /// dashboard's secondary left-column card.
    private var fileVaultCard: some View {
        HStack(spacing: 14) {
            Image(systemName: viewModel.fileVaultIconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(heroTint)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(sectionAccent.opacity(0.18))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("Disk Encryption")
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.fileVaultLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            StatusDot(color: fileVaultHealthColor)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("health.filevault")
    }

}

// MARK: - Mac Health hero

/// One row in the hero's system snapshot — an icon, a label, and a value (e.g.
/// Chip · Apple M3 Max). Built in `HealthMonitorView` from the view-model so the
/// hero stays a pure render of the data it's handed. Deliberately carries no
/// health color: this is device/OS context, not another traffic-light metric.
private struct MacHealthDetail: Identifiable {
    let icon: String
    let title: String
    let value: String
    var id: String { title }
}

/// The dashboard-style hero card: a glowing ring around a laptop, the single
/// overall verdict, the contributing checks, the boot volume's fill, and an
/// info affordance. Always rendered dark (like the reference design) so it
/// reads as the focal element regardless of system appearance; text colors are
/// therefore pinned light rather than semantic.
private struct MacHealthHero: View {
    /// `nil` means the boot volume hasn't been measured yet — the card shows a
    /// neutral "Measuring…" state instead of a confident verdict.
    let status: MacHealthStatus?
    /// Device/OS context rows shown in the hero's system snapshot.
    let details: [MacHealthDetail]
    let volumeName: String
    let diskUsageDetail: String
    let diskRatio: Double

    @State private var showingInfo = false

    /// The status's signature color (gray while measuring). Drives the verdict
    /// ring, the title, the laptop tint, and the disk bar so the health signal
    /// reads clearly.
    private var accent: Color { status?.accentColor ?? Color(white: 0.55) }

    /// The section's signature green, pulled from the single source of truth in
    /// `SectionTheme`. Drives the hero's base gradient, glow, border, and lift so
    /// the tile's overall vibe stays locked to the Health Monitor section no
    /// matter which verdict tint the ring is showing.
    private let sectionAccent = NavigationSection.healthMonitor.theme.accent

    private var titleText: String {
        status?.title ?? String(localized: "Measuring…")
    }

    private var summaryText: String {
        status?.summary ?? String(localized: "Checking your Mac's health…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Health:")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(titleText)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(accent)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("health.hero.status")
                        infoButton
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)

                HealthRing(
                    color: accent,
                    fillRatio: status?.score ?? 0,
                    isMeasuring: status == nil
                )
                    .frame(width: 140, height: 140)
                    .overlay { heroArt }
                    .accessibilityIdentifier("health.hero.ring")
            }

            Text(summaryText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            // Device/OS context the metric tiles don't show. Hidden while
            // measuring (status == nil) so it appears with the verdict.
            if status != nil {
                Spacer(minLength: 16)
                detailList
            }

            Spacer(minLength: 12)

            // While measuring (status == nil) the disk reads zero bytes, so
            // hide the block rather than show "Zero KB of Zero KB used".
            if status != nil {
                diskBlock
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(heroBackground)
        .clipShape(.rect(cornerRadius: 12))
        // A hairline accent border and a soft green lift set the hero apart
        // from the flat glass tiles without leaving the section's palette.
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(sectionAccent.opacity(0.30), lineWidth: 1)
        )
        .shadow(color: sectionAccent.opacity(0.20), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.hero")
    }

    /// Small "i" affordance beside the verdict that explains how the overall
    /// health score is derived.
    private var infoButton: some View {
        Button {
            showingInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
            Text("Your Mac's overall health, derived from how full the disk is and the individual hardware and security checks.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: 260)
        }
        .help("How the health score is calculated")
        .accessibilityHidden(true)
    }

    /// Grouped system snapshot — an icon, a label, and a value per row (Chip,
    /// macOS, Uptime). Sits in the hero's middle so the space carries device/OS
    /// context the metric tiles don't, rather than a void. No status dots: this
    /// is context, not another traffic-light reading.
    private var detailList: some View {
        VStack(spacing: 0) {
            ForEach(Array(details.enumerated()), id: \.element.id) { index, detail in
                if index > 0 {
                    Divider().overlay(Color.white.opacity(0.08))
                }
                HStack(spacing: 10) {
                    Image(systemName: detail.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 20)
                    Text(detail.title)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 8)
                    Text(detail.value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.hero.system")
    }

    /// Boot-volume name with its "used of total" fill below a slim bar.
    private var diskBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(volumeName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(diskUsageDetail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("health.hero.diskusage")
            }
            ProgressView(value: diskRatio)
                .progressViewStyle(.linear)
                .tint(accent)
                .accessibilityIdentifier("health.hero.diskbar")
        }
    }

    /// Health Monitor's own hero art centered inside the ring: the pink iMac
    /// from the shared 3D family showing an ECG pulse on its screen, so the card
    /// reads as Health Monitor rather than borrowing Smart Scan's art.
    private var heroArt: some View {
        Image("healthMonitor")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 108, height: 108)
            .accessibilityHidden(true)
    }

    /// Elevated indigo panel that reads as a special surface: a deep
    /// indigo-violet base, a blue accent bloom behind the ring, and a soft top
    /// sheen for a premium, glassy lift.
    private var heroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.14, blue: 0.42),
                    Color(red: 0.10, green: 0.08, blue: 0.26)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [sectionAccent.opacity(0.28), .clear],
                center: UnitPoint(x: 0.82, y: 0.30),
                startRadius: 8,
                endRadius: 280
            )
            RadialGradient(
                colors: [Color.white.opacity(0.06), .clear],
                center: UnitPoint(x: 0.2, y: 0.0),
                startRadius: 0,
                endRadius: 320
            )
        }
    }
}

/// The glowing health ring — a score gauge whose bright arc fills to the
/// verdict's `score`, so the arc length itself signals how healthy the Mac is.
/// Isolated to take only `color`, the fill fraction, and a measuring flag so
/// its fill animation keeps a stable identity and is not reset by the
/// surrounding view re-evaluating on every system-telemetry tick. The arc grows
/// from empty when a verdict first lands, then eases to each new value.
private struct HealthRing: View {
    let color: Color
    /// Fraction of the circle the bright arc fills, from `MacHealthStatus.score`.
    let fillRatio: Double
    let isMeasuring: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: Double = 0

    var body: some View {
        ZStack {
            // Soft outer bloom.
            Circle()
                .stroke(color.opacity(0.35), lineWidth: 14)
                .blur(radius: 24)
            // Dim full-circle track.
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 6)
            // Bright scored arc — hidden while measuring so the ring reads as
            // neutral until a verdict lands, then filling to the verdict score.
            // Starts at 12 o'clock and sweeps clockwise like a gauge.
            Circle()
                .trim(from: 0.0, to: fill)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            color.opacity(0.35), color, .white.opacity(0.9)
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .blur(radius: 0.5)
                .shadow(color: color.opacity(0.5), radius: 6)
                .opacity(isMeasuring ? 0.0 : 1.0)
        }
        .onAppear { animateFill() }
        // The real app starts measuring (nil) and resolves on the first tick;
        // grow the arc when the verdict arrives, not just on appear.
        .onChange(of: isMeasuring) { _, _ in animateFill() }
        .onChange(of: fillRatio) { _, _ in animateFill() }
    }

    /// Eases the arc to the current verdict score; snaps immediately under
    /// Reduce Motion. While measuring the arc stays empty (and hidden).
    private func animateFill() {
        let target = isMeasuring ? 0 : fillRatio
        guard !reduceMotion else { fill = target; return }
        withAnimation(.smooth(duration: 0.8)) { fill = target }
    }
}

extension MacHealthStatus {
    /// Signature color per tier — a traffic-light ramp from critical red through
    /// orange and amber to a healthy green, so a healthy Mac reads in the same
    /// green as the per-metric gauges and dots rather than a competing hue.
    /// Shared by the Health Monitor hero and the menu bar panel so the verdict
    /// reads in the same colour in both places.
    var accentColor: Color {
        switch self {
        case .critical:          return Color(red: 1.00, green: 0.45, blue: 0.38)
        case .requiresAttention: return Color(red: 1.00, green: 0.60, blue: 0.35)
        case .fair:              return Color(red: 0.99, green: 0.80, blue: 0.36)
        case .good:              return Color(red: 0.56, green: 0.85, blue: 0.55)
        case .excellent:         return Color(red: 0.40, green: 0.85, blue: 0.66)
        }
    }
}

// MARK: - Subviews

/// Reusable metric tile. Keeps card geometry consistent across the grid so the
/// user's eye doesn't have to retrain on each tile: a prominent accent icon and
/// info affordance up top, the metric title, and the live value below.
private struct HealthCard<Content: View>: View {
    let icon: String
    let title: String
    /// Section accent (blue) for the icon tile's rounded background.
    let accent: Color
    /// Tint for the icon glyph itself — the pink hero family, set apart from
    /// the blue tile background.
    let iconColor: Color
    /// Status dot color — the overall Mac Health verdict color, so the dot
    /// tracks the Mac's health at a glance.
    let statusColor: Color
    /// Plain-language explanation shown in the card's info popover.
    let info: String
    @ViewBuilder var content: Content

    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                iconTile
                Spacer()
                StatusDot(color: statusColor)
                infoButton
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    /// Prominent rounded icon tile in the shared verdict accent, echoing the
    /// reference dashboard's large card icons.
    private var iconTile: some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(iconColor)
            .frame(width: 46, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(accent.opacity(0.16))
            )
    }

    private var infoButton: some View {
        Button {
            showingInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInfo, arrowEdge: .top) {
            Text(info)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: 240)
        }
        .help(info)
        .accessibilityHidden(true)
    }
}

/// 8pt accent dot used for the per-card indicator and the Disk Encryption card.
/// Tinted with the shared verdict accent so every tile reads in one hue.
private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

/// Compact pill rendering of the memory pressure level, sitting next to the
/// raw "used / total" string on the RAM card. Tinted with the shared verdict
/// accent so it stays in step with the rest of the section.
private struct PressureBadge: View {
    let label: String
    let accent: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(accent.opacity(0.15))
            )
            .foregroundStyle(accent)
    }
}

/// Circular fill gauge for a single metric: a dim full-circle track under a
/// bright arc trimmed to `ratio`, with a small glyph in the eye. Tinted by the
/// metric's own health color so the instrument itself carries the verdict. The
/// arc grows from empty on first appearance so the card reads as "filling in"
/// rather than snapping to a static value.
private struct HealthGauge: View {
    let ratio: Double
    let color: Color
    /// SF Symbol shown small in the eye of the ring — used when there is no
    /// live value worth repeating (e.g. Battery, whose % is already the metric).
    var centerSymbol: String? = nil
    /// Live value shown in the eye of the ring instead of a glyph, so the gauge
    /// reads its own number (e.g. Memory "58%", CPU "30%") rather than echoing
    /// the tile's icon.
    var centerText: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: Double = 0

    private let lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                // A hair of minimum trim keeps the rounded cap visible even at
                // a zero reading, so the ring never looks like a bare track.
                .trim(from: 0, to: max(0.02, fill))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 5)
            if let centerText {
                Text(centerText)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else if let centerSymbol {
                Image(systemName: centerSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .onAppear {
            guard !reduceMotion else { fill = ratio; return }
            withAnimation(.smooth(duration: 0.7)) { fill = ratio }
        }
        .onChange(of: ratio) { _, newValue in
            withAnimation(.smooth(duration: 0.4)) { fill = newValue }
        }
        .accessibilityHidden(true)
    }
}

/// Filled circular badge for a binary/verdict metric that has no continuous
/// value to fill a gauge — Disk Health's SMART self-check. The glyph and its
/// soft disc both take the metric's health color so the badge reads as the
/// verdict at a glance.
private struct HealthBadge: View {
    let symbol: String
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.16))
            Circle()
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.4), radius: 5)
        }
        .accessibilityHidden(true)
    }
}

/// One-shot entrance for the metric tiles: each fades and rises into place with
/// a per-index delay so the grid assembles in a quick cascade rather than
/// popping in all at once, matching the Smart Scan results grid.
private struct StaggeredEntrance: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(
                .smooth(duration: 0.4).delay(Double(index) * 0.08),
                value: appeared
            )
    }
}

private extension View {
    func staggeredEntrance(index: Int, appeared: Bool) -> some View {
        modifier(StaggeredEntrance(index: index, appeared: appeared))
    }
}

#Preview("Health Monitor") {
    HealthMonitorView(service: SystemStatsService(autostart: false))
        .frame(width: 900, height: 600)
}

/// Renders the hero card across the verdict tiers so the design is inspectable
/// without live telemetry (the live `SystemStatsService(autostart: false)`
/// preview above only ever shows the "Measuring…" state off its empty disk).
#Preview("Mac Health states") {
    let sampleDetails: [MacHealthDetail] = [
        MacHealthDetail(icon: "cpu", title: "Chip", value: "Apple M3 Max"),
        MacHealthDetail(icon: "apple.logo", title: "macOS", value: "macOS 26.1"),
        MacHealthDetail(icon: "clock", title: "Uptime", value: "4d 3h")
    ]
    return ScrollView {
        VStack(spacing: 16) {
            MacHealthHero(status: nil, details: sampleDetails, volumeName: "Macintosh HD", diskUsageDetail: "", diskRatio: 0.0)
            MacHealthHero(status: .excellent, details: sampleDetails, volumeName: "Macintosh HD", diskUsageDetail: "121 GB of 494 GB used", diskRatio: 0.24)
            MacHealthHero(status: .good, details: sampleDetails, volumeName: "Macintosh HD", diskUsageDetail: "270 GB of 494 GB used", diskRatio: 0.55)
            MacHealthHero(status: .fair, details: sampleDetails, volumeName: "Macintosh HD", diskUsageDetail: "380 GB of 494 GB used", diskRatio: 0.77)
            MacHealthHero(status: .requiresAttention, details: sampleDetails, volumeName: "Macintosh HD", diskUsageDetail: "430 GB of 494 GB used", diskRatio: 0.87)
            MacHealthHero(status: .critical, details: sampleDetails, volumeName: "Macintosh HD", diskUsageDetail: "479 GB of 494 GB used", diskRatio: 0.97)
        }
        .frame(width: 360)
        .padding(20)
    }
    .frame(width: 420, height: 720)
}
