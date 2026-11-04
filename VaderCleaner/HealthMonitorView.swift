// HealthMonitorView.swift
// Health Monitor — a verdict banner that names what to watch and offers the fix, a list of long-lived health checks, live memory and CPU tiles, and a one-line system footer, bound to SystemStatsService via HealthMonitorViewModel.

import SwiftUI
import VaderCleanerCore

/// The Health Monitor answers two questions in order: is anything wrong, and
/// what should I do about it. The banner says so in a sentence and offers the
/// one action that helps. Below it, long-lived health (storage, battery, the
/// drive's own condition, encryption) is kept apart from the moment-to-moment
/// load (memory, CPU), because a reading that changes every two seconds is
/// activity, not health. Every row uses one status scale — Good, Watch, Act
/// now — so a color means the same thing everywhere on the screen.
struct HealthMonitorView: View {

    @State private var viewModel: HealthMonitorViewModel

    /// Whether the Mac has completed at least one scan. Pre-first-scan the
    /// verdict caps at Good (see `displayedHealth`), matching the menu bar
    /// panel so the two surfaces never disagree.
    private let hasScanned: Bool

    /// Opens Smart Scan and starts a scan when the verdict's "Free up space"
    /// is pressed.
    private let onFreeUpSpace: () -> Void

    /// Drives the one-shot staggered entrance of the screen's blocks.
    @State private var appeared = false

    init(service: SystemStatsService, hasScanned: Bool, onFreeUpSpace: @escaping () -> Void = {}) {
        _viewModel = State(initialValue: HealthMonitorViewModel(service: service))
        self.hasScanned = hasScanned
        self.onFreeUpSpace = onFreeUpSpace
    }

    /// The verdict tier the banner's glyph colors by: the live derivation
    /// capped by scan state.
    private var displayedHealth: MacHealthStatus? {
        HealthMonitorViewModel.displayedHealth(viewModel.macHealth, hasScanned: hasScanned)
    }

    var body: some View {
        ScrollView {
            // One glass container so the blocks share a render pass. Spacing 0
            // keeps them from blending: the container melts shapes nearer than
            // `spacing` into one surface.
            GlassEffectContainer(spacing: 0) {
                VStack(alignment: .leading, spacing: 24) {
                    HealthVerdictBanner(
                        summary: viewModel.summary(hasScanned: hasScanned),
                        status: displayedHealth,
                        onFreeUpSpace: onFreeUpSpace
                    )
                    .staggeredEntrance(index: 0, appeared: appeared)

                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(String(localized: "Health checks", comment: "Health Monitor section header for long-lived checks."))
                        HealthCheckList(checks: viewModel.checks)
                    }
                    .staggeredEntrance(index: 1, appeared: appeared)

                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(String(localized: "Right now", comment: "Health Monitor section header for live memory and CPU load."))
                        HStack(spacing: 14) {
                            memoryTile
                            cpuTile
                        }
                    }
                    .staggeredEntrance(index: 2, appeared: appeared)

                    Text(viewModel.systemLine)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.leading, 4)
                        .accessibilityIdentifier("health.systemLine")
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(NavigationSection.healthMonitor.title)
        .onAppear { appeared = true }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Right now

    private var memoryTile: some View {
        LoadTile(
            icon: "memorychip",
            title: String(localized: "Memory", comment: "Health Monitor live tile title."),
            value: viewModel.memoryValue,
            label: viewModel.memoryLoadLabel,
            color: Self.color(for: HealthMonitorViewModel.pressureColor(for: viewModel.ramPressureLevel)),
            valueIdentifier: "health.ram.usage"
        )
        .accessibilityIdentifier("health.card.ram")
    }

    private var cpuTile: some View {
        LoadTile(
            icon: "cpu",
            title: String(localized: "CPU", comment: "Health Monitor live tile title."),
            value: viewModel.cpuPercent,
            label: viewModel.cpuLoadLabel,
            color: Self.color(for: HealthMonitorViewModel.cpuColor(for: viewModel.service.cpuUsage)),
            valueIdentifier: "health.cpu.percent"
        )
        .accessibilityIdentifier("health.card.cpu")
    }

    /// Maps the view-model's framework-free `StatusColor` to a softened SwiftUI
    /// color tuned for the dark glass tiles — the same warm-to-cool ramp the
    /// Mac Health verdict uses, so a green row and a green verdict read in
    /// the same hue family.
    fileprivate static func color(for status: StatusColor) -> Color {
        switch status {
        case .green:  return Color(red: 0.40, green: 0.85, blue: 0.66)
        case .yellow: return Color(red: 0.99, green: 0.78, blue: 0.34)
        case .red:    return Color(red: 1.00, green: 0.45, blue: 0.38)
        case .gray:   return Color(white: 0.55)
        }
    }

    /// The same ramp keyed by a check's status.
    fileprivate static func color(for status: HealthCheck.Status) -> Color {
        switch status {
        case .good: return color(for: StatusColor.green)
        case .watch: return color(for: StatusColor.yellow)
        case .act: return color(for: StatusColor.red)
        case .unknown: return color(for: StatusColor.gray)
        }
    }
}

// MARK: - Verdict banner

/// The verdict in a sentence: the section's art, a headline, the reason that
/// names what to watch, and — when the disk is what needs attention — the
/// button that goes and fixes it. Laid out like every section dashboard's
/// header (`SectionDashboard`): centered hero art, headline, subheadline, one
/// glass action pill — so the Health Monitor reads as part of the same app.
private struct HealthVerdictBanner: View {

    let summary: HealthSummary
    /// `nil` while the boot volume is still unmeasured.
    let status: MacHealthStatus?
    let onFreeUpSpace: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image("healthMonitor")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                // A fixed size, not `SectionDashboard`'s max frame: inside a
                // ScrollView nothing offers a height, so a max frame shrinks
                // the art to its native size.
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(status?.accentColor ?? Color(white: 0.55))
                        .accessibilityHidden(true)
                    Text(summary.headline)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("health.hero.status")
                }
                Text(summary.reason)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("health.hero.reason")
            }
            .multilineTextAlignment(.center)
            if summary.action == .freeUpSpace {
                Button(action: onFreeUpSpace) {
                    Text(String(localized: "Free Up Space", comment: "Health verdict action opening Smart Scan and starting a scan."))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.vaderTileGlass)
                .controlSize(.large)
                .accessibilityIdentifier("health.hero.freeUpSpace")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.hero")
    }

    private var statusSymbol: String {
        switch status {
        case nil: return "circle.dotted"
        case .excellent?, .good?: return "checkmark.circle.fill"
        case .fair?, .requiresAttention?: return "exclamationmark.circle.fill"
        case .critical?: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Health checks

/// The long-lived checks as one list: a glance down the status column says
/// whether anything needs doing.
private struct HealthCheckList: View {

    let checks: [HealthCheck]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.1))
                        .frame(height: 1)
                        .padding(.leading, 66)
                }
                HealthCheckRow(check: check)
            }
        }
        .padding(.vertical, 4)
        .vaderTileGlass()
    }
}

private struct HealthCheckRow: View {

    let check: HealthCheck

    private var color: Color { HealthMonitorView.color(for: check.status) }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(chipGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(check.detail)
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
                    .lineLimit(1)
                // Under its own figure, so the bar reads as part of the
                // reading rather than a separate gauge across the row.
                if let ratio = check.ratio {
                    FillBar(ratio: ratio, color: color)
                        .frame(maxWidth: 220)
                        .frame(height: 5)
                        .padding(.top, 5)
                        .accessibilityIdentifier(check.kind == .storage ? "health.hero.diskbar" : "health.battery.bar")
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            statusMark
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// Only a status that asks for something gets a pill, so the one row
    /// that needs the eye stands out. A Good row gets a quiet checkmark and an
    /// unknown one a muted word: neither competes with a Watch or Act now.
    @ViewBuilder
    private var statusMark: some View {
        switch check.status {
        case .good:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityLabel(check.status.label)
        case .unknown:
            Text(check.status.label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        case .watch, .act:
            Text(check.status.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .frame(minWidth: 62)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.16), in: Capsule())
        }
    }

    /// A hue per kind, like System Settings' icon tiles. Kept to blues and
    /// violets so no chip can be mistaken for a status: green, amber, and red
    /// mean Good, Watch, and Act now everywhere on this screen.
    private var chipGradient: LinearGradient {
        let colors: [Color]
        switch check.kind {
        case .storage: colors = [Color(red: 0.29, green: 0.60, blue: 1.00), Color(red: 0.18, green: 0.40, blue: 0.92)]
        case .battery: colors = [Color(red: 0.25, green: 0.80, blue: 0.86), Color(red: 0.10, green: 0.56, blue: 0.70)]
        case .drive: colors = [Color(red: 0.72, green: 0.48, blue: 1.00), Color(red: 0.50, green: 0.28, blue: 0.90)]
        case .encryption: colors = [Color(red: 0.56, green: 0.62, blue: 0.76), Color(red: 0.36, green: 0.40, blue: 0.54)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var icon: String {
        switch check.kind {
        case .storage: return "internaldrive"
        case .battery: return "battery.75percent"
        case .drive: return "stethoscope"
        case .encryption: return "lock.fill"
        }
    }

    /// The identifiers the Health Monitor UI tests already look for.
    private var identifier: String {
        switch check.kind {
        case .storage: return "health.card.disk"
        case .battery: return "health.card.battery"
        case .drive: return "health.card.smart"
        case .encryption: return "health.filevault"
        }
    }
}

/// A thin capsule bar for a check with a measurable share: the disk used, or
/// the battery capacity left.
private struct FillBar: View {

    let ratio: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(ratio, 0), 1))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Right now

/// One live reading: its value and what that value means in words, colored
/// by the same scale as the checks.
private struct LoadTile: View {

    let icon: String
    let title: String
    let value: String
    let label: String
    let color: Color
    let valueIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.7))
            // The value and what it means share a line, so the tile is as
            // tall as its content rather than a mostly empty slab.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .accessibilityIdentifier(valueIdentifier)
                Spacer(minLength: 8)
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vaderTileGlass()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shared

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

/// One-shot entrance for the screen's blocks: each fades and rises into place
/// with a per-index delay so the screen assembles in a quick cascade rather
/// than popping in all at once, matching the Smart Scan results grid.
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
    HealthMonitorView(service: SystemStatsService(autostart: false), hasScanned: true)
        .frame(width: 900, height: 600)
}
