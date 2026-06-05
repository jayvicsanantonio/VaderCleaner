// HealthMonitorView.swift
// Health Monitor detail view — 5 stat cards (Battery, Disk SMART, RAM, CPU, Disk Space) plus a FileVault footer, bound to SystemStatsService via HealthMonitorViewModel.

import SwiftUI

/// Card-style grid showing live system health. Each card is a small fixed-shape
/// `HealthCard` with an SF Symbol, label, primary value, optional secondary
/// value, and a status dot driven by `HealthMonitorViewModel`'s `StatusColor`.
///
/// The grid uses `LazyVGrid` with `.adaptive(minimum: 260)` so the card shelf
/// re-flows on window resize without explicit breakpoints. FileVault — being
/// a binary security toggle rather than a continuously varying reading — sits
/// below the grid as a single info row, matching the spec.
struct HealthMonitorView: View {

    @State private var viewModel: HealthMonitorViewModel

    init(service: SystemStatsService) {
        _viewModel = State(initialValue: HealthMonitorViewModel(service: service))
    }

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The hero card leads with one overall verdict and the boot
                // volume's fill, mirroring the dashboard "Mac Health" panel.
                // The per-metric cards below remain the detailed breakdown.
                MacHealthHero(
                    status: viewModel.macHealth,
                    volumeName: viewModel.diskVolumeName,
                    diskUsageDetail: viewModel.diskUsageDetail,
                    diskRatio: viewModel.diskRatio
                )
                // Group the tiles in one container so adjacent glass cards
                // sample each other and refract consistently as the grid
                // reflows on resize.
                GlassEffectContainer(spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 16) {
                        batteryCard
                        smartCard
                        ramCard
                        cpuCard
                        diskCard
                    }
                }
                Divider()
                fileVaultRow
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.healthMonitor.title)
    }

    // MARK: - Cards

    private var batteryCard: some View {
        HealthCard(
            icon: "battery.100",
            title: "Battery Health",
            statusColor: viewModel.batteryColor
        ) {
            switch viewModel.batteryAvailability {
            case .unknown:
                Text("—")
                    .font(.title2.weight(.semibold))
                Text("Checking battery")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .absent:
                Text("—")
                    .font(.title2.weight(.semibold))
                Text("No internal battery")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .present(let stats):
                Text(HealthMonitorViewModel.batteryCapacityString(stats))
                    .font(.title2.weight(.semibold))
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
            statusColor: viewModel.smartColor
        ) {
            Text(viewModel.smartLabel)
                .font(.title2.weight(.semibold))
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
            statusColor: viewModel.ramPressureColor
        ) {
            Text(viewModel.ramUsage)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("health.ram.usage")
            HStack(spacing: 8) {
                PressureBadge(level: viewModel.ramPressureLevel, label: viewModel.ramPressureLabel)
                Spacer()
            }
        }
        .accessibilityIdentifier("health.card.ram")
    }

    private var cpuCard: some View {
        HealthCard(
            icon: "cpu",
            title: "CPU Load",
            statusColor: viewModel.cpuColor
        ) {
            Text(viewModel.cpuPercent)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("health.cpu.percent")
            ProgressView(value: viewModel.cpuRatio)
                .progressViewStyle(.linear)
                .tint(viewModel.cpuColor.color)
        }
        .accessibilityIdentifier("health.card.cpu")
    }

    private var diskCard: some View {
        HealthCard(
            icon: "externaldrive",
            title: "Disk Space",
            statusColor: viewModel.diskColor
        ) {
            Text(viewModel.diskUsage)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("health.disk.usage")
            ProgressView(value: viewModel.diskRatio)
                .progressViewStyle(.linear)
                .tint(viewModel.diskColor.color)
        }
        .accessibilityIdentifier("health.card.disk")
    }

    // MARK: - FileVault footer

    private var fileVaultRow: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.fileVaultIconName)
                .font(.title3)
                .foregroundStyle(viewModel.fileVaultColor.color)
            Text(viewModel.fileVaultLabel)
                .font(.callout)
            StatusDot(color: viewModel.fileVaultColor)
            Spacer()
        }
        .padding(.horizontal, 4)
        .accessibilityIdentifier("health.filevault")
    }

}

// MARK: - Mac Health hero

/// The dashboard-style hero card: a glowing ring around a laptop, the single
/// overall verdict, and the boot volume's fill. Always rendered dark (like the
/// reference design) so it reads as the focal element regardless of system
/// appearance; text colors are therefore pinned light rather than semantic.
private struct MacHealthHero: View {
    /// `nil` means the boot volume hasn't been measured yet — the card shows a
    /// neutral "Measuring…" state instead of a confident verdict.
    let status: MacHealthStatus?
    let volumeName: String
    let diskUsageDetail: String
    let diskRatio: Double

    /// The status's signature color (gray while measuring). Drives the ring,
    /// the title, the laptop tint, the disk bar, and the background glow.
    private var accent: Color { status?.accentColor ?? Color(white: 0.55) }

    private var titleText: String {
        status?.title ?? String(localized: "Measuring…")
    }

    private var summaryText: String {
        status?.summary ?? String(localized: "Checking your Mac's health…")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mac Health:")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(titleText)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.top, 2)
                    .accessibilityIdentifier("health.hero.status")
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                Spacer(minLength: 24)

                // While measuring (status == nil) the disk reads zero bytes, so
                // hide the block rather than show "Zero KB of Zero KB used".
                if status != nil {
                    diskBlock
                }
            }

            Spacer(minLength: 0)

            HealthRing(color: accent, isMeasuring: status == nil)
                .frame(width: 190, height: 190)
                .overlay { laptop }
                .accessibilityIdentifier("health.hero.ring")
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(heroBackground)
        .clipShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.hero")
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
            .font(.system(size: 56, weight: .light))
            .foregroundStyle(
                LinearGradient(
                    colors: [.white.opacity(0.95), accent.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .accessibilityHidden(true)
    }

    /// Fixed dark gradient with the accent glow concentrated behind the ring,
    /// matching the reference design's always-dark hero panel.
    private var heroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.09, blue: 0.16),
                    Color(red: 0.17, green: 0.13, blue: 0.27)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [accent.opacity(0.30), .clear],
                center: UnitPoint(x: 0.82, y: 0.42),
                startRadius: 8,
                endRadius: 300
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

private extension MacHealthStatus {
    /// Signature color per tier, matching the reference design's ramp from a
    /// warm critical red through amber and teal to a confident blue.
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

/// Reusable card wrapper. Keeps card geometry consistent across the grid so
/// the user's eye doesn't have to retrain on each tile.
private struct HealthCard<Content: View>: View {
    let icon: String
    let title: String
    let statusColor: StatusColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                StatusDot(color: statusColor)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

/// 8pt traffic-light dot used for the per-card status indicator and the
/// FileVault footer.
private struct StatusDot: View {
    let color: StatusColor

    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

/// Compact pill rendering of the memory pressure level, sitting next to the
/// raw "used / total" string on the RAM card.
private struct PressureBadge: View {
    let level: MemoryPressureLevel
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(HealthMonitorViewModel.pressureColor(for: level).color.opacity(0.15))
            )
            .foregroundStyle(HealthMonitorViewModel.pressureColor(for: level).color)
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
        .padding(20)
    }
    .frame(width: 740, height: 720)
}
