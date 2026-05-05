// HealthMonitorViewModel.swift
// View-model behind the Health Monitor — formats SystemStatsService values into card-ready display strings and traffic-light status colors.

import Foundation
import Combine

/// Traffic-light state the Health Monitor cards bind to.
///
/// We deliberately don't use `SwiftUI.Color` here so the view-model — and its
/// tests — stay free of SwiftUI imports. The view layer maps `StatusColor` →
/// `Color` once at the leaf. The same enum will back the menu bar (Prompt 10)
/// and notification dispatcher (Prompt 11) palette.
enum StatusColor: Equatable {
    case green
    case yellow
    case red
    case gray
}

/// Drives the Health Monitor feature view.
///
/// The view-model is intentionally thin: it holds a reference to
/// `SystemStatsService` (the live polling source) and exposes computed
/// properties that render the published service state into card-ready strings
/// and `StatusColor` values.
///
/// All formatting and color-mapping logic is exposed as `static` pure
/// functions so unit tests can pin the rules without instantiating a service
/// or driving real CPU/RAM/disk telemetry. Instance properties simply forward
/// the live service state through those formatters.
@MainActor
final class HealthMonitorViewModel: ObservableObject {

    /// Live data source. Marked `unowned` (via the strong reference held in
    /// the consuming view's `@EnvironmentObject` chain) — the service is
    /// app-scope (`VaderCleanerApp.systemStats`) and outlives every view-model
    /// derived from it.
    let service: SystemStatsService

    init(service: SystemStatsService) {
        self.service = service
    }

    // MARK: - Live-bound display values

    var cpuPercent: String { Self.cpuPercentString(service.cpuUsage) }
    var cpuRatio: Double { Self.cpuRatio(service.cpuUsage) }

    var ramUsage: String { Self.ramUsageString(service.ramUsage) }
    var ramPressureLevel: MemoryPressureLevel { service.ramUsage.pressureLevel }
    var ramPressureLabel: String { Self.pressureLabel(for: ramPressureLevel) }
    var ramPressureColor: StatusColor { Self.pressureColor(for: ramPressureLevel) }

    var diskUsage: String { Self.diskSpaceString(service.diskSpace) }
    var diskRatio: Double { Self.diskUsageRatio(service.diskSpace) }
    var diskColor: StatusColor { Self.diskColor(for: service.diskSpace) }

    var battery: BatteryStats? { service.batteryHealth }
    var batteryColor: StatusColor { Self.batteryColor(for: battery) }
    var batteryCapacity: String? { battery.map(Self.batteryCapacityString) }
    var batteryCondition: String? { battery?.condition }
    var batteryCycleCount: Int? { battery?.cycleCount }

    var smartStatus: SMARTStatus { service.diskSMARTStatus }
    var smartLabel: String { Self.smartLabel(for: smartStatus) }
    var smartColor: StatusColor { Self.smartColor(for: smartStatus) }

    var fileVaultEnabled: Bool { service.fileVaultEnabled }
    var fileVaultLabel: String { Self.fileVaultLabel(enabled: fileVaultEnabled) }
    var fileVaultColor: StatusColor { Self.fileVaultColor(enabled: fileVaultEnabled) }

    // MARK: - Pure formatters / color rules

    /// Formats a unit-interval CPU usage to an integer percentage. Inputs
    /// outside `[0, 1]` clamp at the boundary — the service is expected to
    /// clamp first, but the formatter is the last line of defence and is
    /// reused by the menu bar (Prompt 10) and Smart Scan (Prompt 25).
    static func cpuPercentString(_ usage: Double) -> String {
        let clamped = cpuRatio(usage)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// Returns `usage` clamped to `[0, 1]`. Drives the CPU progress bar.
    static func cpuRatio(_ usage: Double) -> Double {
        max(0.0, min(1.0, usage))
    }

    /// Formats RAM byte counts as `"used / total"` in GB. We force the GB unit
    /// (rather than letting `ByteCountFormatter` pick) so 8 GB never renders
    /// as "8,000 MB" on a non-en locale and so the card width stays stable.
    static func ramUsageString(_ stats: MemoryStats) -> String {
        let used = byteString(stats.usedBytes)
        let total = byteString(stats.totalBytes)
        return "\(used) / \(total)"
    }

    /// Formats disk byte counts identically to RAM — see `ramUsageString` for
    /// rationale on locking the unit.
    static func diskSpaceString(_ stats: DiskStats) -> String {
        let used = byteString(stats.usedBytes)
        let total = byteString(stats.totalBytes)
        return "\(used) / \(total)"
    }

    /// `usedBytes / totalBytes` clamped to `[0, 1]`. Returns `0` for zero-byte
    /// totals (pre-first-refresh) so the % bar stays empty rather than NaN.
    static func diskUsageRatio(_ stats: DiskStats) -> Double {
        guard stats.totalBytes > 0 else { return 0.0 }
        let raw = Double(stats.usedBytes) / Double(stats.totalBytes)
        return max(0.0, min(1.0, raw))
    }

    /// Disk fullness color. Below 80% green, 80–95% yellow, above red.
    /// Boundaries are inclusive at the lower bound (a disk exactly at 80%
    /// flips to yellow), matching `MemoryPressureLevel`'s convention.
    static func diskColor(for stats: DiskStats) -> StatusColor {
        let ratio = diskUsageRatio(stats)
        if ratio < diskWarningThreshold { return .green }
        if ratio < diskCriticalThreshold { return .yellow }
        return .red
    }

    /// Threshold at which the disk card flips from green to yellow.
    static let diskWarningThreshold = 0.80

    /// Threshold at which the disk card flips from yellow to red.
    static let diskCriticalThreshold = 0.95

    /// Color for a memory-pressure bucket. Mirrors the disk ramp but reads
    /// off `MemoryPressureLevel` (whose thresholds are pinned in
    /// `SystemStatsService`).
    static func pressureColor(for level: MemoryPressureLevel) -> StatusColor {
        switch level {
        case .nominal: return .green
        case .fair: return .yellow
        case .critical: return .red
        }
    }

    /// Human-readable label for a memory-pressure bucket.
    static func pressureLabel(for level: MemoryPressureLevel) -> String {
        switch level {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .critical: return "Critical"
        }
    }

    /// Battery health color from `BatteryStats.condition`. The IOKit key
    /// flipped from `BatteryHealth` to `BatteryHealthCondition` across macOS
    /// versions, so we accept both vocabularies. `nil` means no internal
    /// battery (Mac mini / Studio / Pro) → gray.
    static func batteryColor(for stats: BatteryStats?) -> StatusColor {
        guard let stats = stats else { return .gray }
        switch stats.condition {
        case "Good", "Normal":
            return .green
        case "Service Battery", "Service Recommended", "Replace Soon", "Replace Now", "Permanent Failure":
            return .red
        default:
            // "Fair", "Poor", "Unknown" or anything unrecognised → yellow.
            // Unknown leans toward yellow rather than gray because the battery
            // *exists* (we have a non-nil `BatteryStats`); the state is just
            // ambiguous, which is itself worth surfacing.
            return .yellow
        }
    }

    /// Formats `maxCapacityPercent` (0.0–1.0) as an integer percentage.
    static func batteryCapacityString(_ stats: BatteryStats) -> String {
        let clamped = max(0.0, min(1.0, stats.maxCapacityPercent))
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// SMART status color. Only `.failing` warrants red — the user needs to
    /// be backing up. `.unknown` is gray (no opinion) rather than yellow
    /// because an Apple Silicon internal disk reporting "Verified" is the
    /// common case and a USB enclosure declining to report SMART is not a
    /// problem the user can act on.
    static func smartColor(for status: SMARTStatus) -> StatusColor {
        switch status {
        case .good: return .green
        case .failing: return .red
        case .unknown: return .gray
        }
    }

    /// Human-readable SMART label.
    static func smartLabel(for status: SMARTStatus) -> String {
        switch status {
        case .good: return "Good"
        case .failing: return "Failing"
        case .unknown: return "Unknown"
        }
    }

    /// FileVault footer text. The "On" / "Off" wording mirrors the
    /// `fdesetup status` vocabulary the service parses.
    static func fileVaultLabel(enabled: Bool) -> String {
        enabled ? "FileVault: On" : "FileVault: Off"
    }

    /// FileVault color. Off is yellow rather than red because disabling
    /// FileVault is a deliberate user choice, not a failure mode — the dot
    /// flags it for visibility without alarmism.
    static func fileVaultColor(enabled: Bool) -> StatusColor {
        enabled ? .green : .yellow
    }

    // MARK: - Helpers

    /// Shared `ByteCountFormatter` configured for GB output. Reused so we
    /// don't re-allocate one per card on every 2-second tick.
    ///
    /// `.useGB` forces the unit even for sub-1 GB inputs ("0.7 GB" rather
    /// than "700 MB"), which keeps the card layout stable as the value
    /// changes. `countStyle = .file` matches what Finder shows.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()

    private static func byteString(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}
