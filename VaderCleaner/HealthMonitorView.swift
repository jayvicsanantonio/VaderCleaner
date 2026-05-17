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

    @StateObject private var viewModel: HealthMonitorViewModel

    init(service: SystemStatsService) {
        _viewModel = StateObject(wrappedValue: HealthMonitorViewModel(service: service))
    }

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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

#Preview {
    HealthMonitorView(service: SystemStatsService(autostart: false))
        .frame(width: 900, height: 600)
}
