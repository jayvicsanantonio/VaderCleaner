// SystemStatsFormatters.swift
// Shared display formatting and traffic-light status colors for system telemetry.

import Foundation

/// Traffic-light state system-stat UI surfaces bind to.
///
/// We deliberately don't use `SwiftUI.Color` here so view-models and their
/// tests stay free of SwiftUI imports. The view layer maps `StatusColor` to
/// `Color` once at the leaf.
enum StatusColor: Equatable {
    case green
    case yellow
    case red
    case gray
}

/// Pure formatting helpers shared by system-stat view-models.
enum SystemStatsFormatters {

    /// Formats a unit-interval CPU usage to an integer percentage. Inputs
    /// outside `[0, 1]` clamp at the boundary.
    static func cpuPercentString(_ usage: Double) -> String {
        let clamped = unitRatio(usage)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// Returns `value` clamped to `[0, 1]`.
    static func unitRatio(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    /// Formats memory byte counts as `"used / total"` in GB.
    static func memoryUsageString(_ stats: MemoryStats) -> String {
        usedTotalString(usedBytes: stats.usedBytes, totalBytes: stats.totalBytes)
    }

    /// Formats disk byte counts as `"used / total"` in GB.
    static func diskUsageString(_ stats: DiskStats) -> String {
        usedTotalString(usedBytes: stats.usedBytes, totalBytes: stats.totalBytes)
    }

    /// Formats `maxCapacityPercent` (0.0-1.0) as an integer percentage.
    static func batteryCapacityString(_ stats: BatteryStats) -> String {
        let clamped = unitRatio(stats.maxCapacityPercent)
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// Human-readable label for a memory-pressure bucket.
    static func pressureLabel(for level: MemoryPressureLevel) -> String {
        switch level {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .critical: return "Critical"
        }
    }

    /// Color for a memory-pressure bucket.
    static func pressureColor(for level: MemoryPressureLevel) -> StatusColor {
        switch level {
        case .nominal: return .green
        case .fair: return .yellow
        case .critical: return .red
        }
    }

    /// Formats a byte count in GB with the same Finder-style units across
    /// Health Monitor and menu bar surfaces.
    static func byteString(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func usedTotalString(usedBytes: UInt64, totalBytes: UInt64) -> String {
        let used = byteString(usedBytes)
        let total = byteString(totalBytes)
        return "\(used) / \(total)"
    }

    /// Shared `ByteCountFormatter` configured for GB output. Reused so we
    /// don't re-allocate one per card on every telemetry tick.
    ///
    /// `.useGB` forces the unit even for sub-1 GB inputs ("0.7 GB" rather
    /// than "700 MB"), which keeps layout stable as values change.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()
}
