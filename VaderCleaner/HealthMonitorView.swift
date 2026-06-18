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
    /// prominent tile icons.
    private let sectionAccent = NavigationSection.healthMonitor.theme.accent

    /// The overall Mac Health verdict color (gray while measuring). Drives the
    /// status dots and progress bars so they track the Mac's health at a glance.
    private var verdictAccent: Color {
        viewModel.macHealth?.accentColor ?? Color(white: 0.55)
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
                        batteryCard
                        smartCard
                    }
                    HStack(spacing: 16) {
                        ramCard
                        cpuCard
                    }
                    diskCard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.healthMonitor.title)
    }

    // MARK: - Cards

    private var batteryCard: some View {
        HealthCard(
            icon: "battery.100",
            title: "Battery Health",
            accent: sectionAccent,
            statusColor: verdictAccent,
            info: "Battery condition and capacity relative to when it was new, plus lifetime charge cycles."
        ) {
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
                    .accessibilityIdentifier("health.battery.capacity")
                Text(stats.condition)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(stats.cycleCount) cycles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("health.card.battery")
    }

    private var smartCard: some View {
        HealthCard(
            icon: "internaldrive",
            title: "Disk Health",
            accent: sectionAccent,
            statusColor: verdictAccent,
            info: "The drive's SMART self-assessment. \"Good\" means the disk reports no predicted failures."
        ) {
            Text(viewModel.smartLabel)
                .font(.title.weight(.semibold))
                .accessibilityIdentifier("health.smart.label")
            Text("SMART status")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("health.card.smart")
    }

    private var ramCard: some View {
        HealthCard(
            icon: "memorychip",
            title: "RAM Pressure",
            accent: sectionAccent,
            statusColor: verdictAccent,
            info: "Memory in use versus total, with the system's current memory-pressure level."
        ) {
            Text(viewModel.ramUsage)
                .font(.title.weight(.semibold))
                .accessibilityIdentifier("health.ram.usage")
            HStack(spacing: 8) {
                PressureBadge(label: viewModel.ramPressureLabel, accent: sectionAccent)
                Spacer()
            }
        }
        .accessibilityIdentifier("health.card.ram")
    }

    private var cpuCard: some View {
        HealthCard(
            icon: "cpu",
            title: "CPU Load",
            accent: sectionAccent,
            statusColor: verdictAccent,
            info: "Share of processor capacity currently in use across all cores."
        ) {
            Text(viewModel.cpuPercent)
                .font(.title.weight(.semibold))
                .accessibilityIdentifier("health.cpu.percent")
            ProgressView(value: viewModel.cpuRatio)
                .progressViewStyle(.linear)
                .tint(verdictAccent)
        }
        .accessibilityIdentifier("health.card.cpu")
    }

    private var diskCard: some View {
        HealthCard(
            icon: "externaldrive",
            title: "Disk Space",
            accent: sectionAccent,
            statusColor: verdictAccent,
            info: "How full the boot volume is. Reclaiming space keeps your Mac responsive."
        ) {
            Text(viewModel.diskUsage)
                .font(.title.weight(.semibold))
                .accessibilityIdentifier("health.disk.usage")
            ProgressView(value: viewModel.diskRatio)
                .progressViewStyle(.linear)
                .tint(verdictAccent)
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
                .foregroundStyle(sectionAccent)
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
            StatusDot(color: verdictAccent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("health.filevault")
    }

}

// MARK: - Mac Health hero

/// The dashboard-style hero card: a glowing ring around a laptop, the single
/// overall verdict, the boot volume's fill, and an info affordance. Always
/// rendered dark (like the reference design) so it reads as the focal element
/// regardless of system appearance; text colors are therefore pinned light
/// rather than semantic.
private struct MacHealthHero: View {
    /// `nil` means the boot volume hasn't been measured yet — the card shows a
    /// neutral "Measuring…" state instead of a confident verdict.
    let status: MacHealthStatus?
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

                HealthRing(color: accent, isMeasuring: status == nil)
                    .frame(width: 140, height: 140)
                    .overlay { laptop }
                    .accessibilityIdentifier("health.hero.ring")
            }

            Text(summaryText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

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
                .padding(14)
                .frame(maxWidth: 260)
        }
        .help("How the health score is calculated")
        .accessibilityHidden(true)
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

    /// Laptop glyph centered inside the ring.
    private var laptop: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(
                LinearGradient(
                    colors: [.white.opacity(0.95), sectionAccent.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
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

/// The glowing health ring. Isolated to take only `color` and a measuring flag
/// so its `.repeatForever` rotation keeps a stable identity and is not reset by
/// the surrounding view re-evaluating on every system-telemetry tick.
private struct HealthRing: View {
    let color: Color
    let isMeasuring: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        ZStack {
            // Soft outer bloom.
            Circle()
                .stroke(color.opacity(0.35), lineWidth: 14)
                .blur(radius: 24)
            // Dim full-circle track.
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 6)
            // Bright sweeping arc — hidden while measuring so the ring reads as
            // neutral until a verdict lands.
            Circle()
                .trim(from: 0.0, to: 0.72)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            color.opacity(0.0), color, .white.opacity(0.9), color, color.opacity(0.0)
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .blur(radius: 0.5)
                .opacity(isMeasuring ? 0.0 : 1.0)
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .onAppear { startSpinIfNeeded() }
        // The real app starts measuring (nil) and resolves on the first tick;
        // kick off the rotation when the verdict arrives, not just on appear.
        // NOTE: this `.repeatForever` rotation means the Health Monitor screen
        // never reaches animation-idle — a UI test that taps an element on this
        // screen will stall in wait-for-idle. Query/assert only (no taps here).
        .onChange(of: isMeasuring) { _, _ in startSpinIfNeeded() }
    }

    private func startSpinIfNeeded() {
        guard !isMeasuring, !reduceMotion, !spin else { return }
        withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) {
            spin = true
        }
    }
}

extension MacHealthStatus {
    /// Signature color per tier, matching the reference design's ramp from a
    /// warm critical red through amber and teal to a confident blue. Shared by
    /// the Health Monitor hero and the menu bar panel so the verdict reads in
    /// the same colour in both places.
    var accentColor: Color {
        switch self {
        case .critical:          return Color(red: 1.00, green: 0.45, blue: 0.38)
        case .requiresAttention: return Color(red: 0.99, green: 0.78, blue: 0.34)
        case .fair:              return Color(red: 0.40, green: 0.85, blue: 0.78)
        case .good:              return Color(red: 0.52, green: 0.80, blue: 0.99)
        case .excellent:         return Color(red: 0.34, green: 0.66, blue: 1.00)
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
    /// Section accent (blue) for the prominent icon tile.
    let accent: Color
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
            .foregroundStyle(accent)
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

extension StatusColor {
    /// Maps the SwiftUI-free `StatusColor` to a `Color` at the leaf, keeping
    /// the view-model and its tests free of SwiftUI imports.
    var color: Color {
        switch self {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .gray: return .secondary
        }
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
    ScrollView {
        VStack(spacing: 16) {
            MacHealthHero(status: nil, volumeName: "Macintosh HD", diskUsageDetail: "", diskRatio: 0.0)
            MacHealthHero(status: .excellent, volumeName: "Macintosh HD", diskUsageDetail: "121 GB of 494 GB used", diskRatio: 0.24)
            MacHealthHero(status: .good, volumeName: "Macintosh HD", diskUsageDetail: "270 GB of 494 GB used", diskRatio: 0.55)
            MacHealthHero(status: .fair, volumeName: "Macintosh HD", diskUsageDetail: "380 GB of 494 GB used", diskRatio: 0.77)
            MacHealthHero(status: .requiresAttention, volumeName: "Macintosh HD", diskUsageDetail: "430 GB of 494 GB used", diskRatio: 0.87)
            MacHealthHero(status: .critical, volumeName: "Macintosh HD", diskUsageDetail: "479 GB of 494 GB used", diskRatio: 0.97)
        }
        .frame(width: 360)
        .padding(20)
    }
    .frame(width: 420, height: 720)
}
