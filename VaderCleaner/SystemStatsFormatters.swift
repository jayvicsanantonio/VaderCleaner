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
        percentString(usage)
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
        percentString(stats.maxCapacityPercent)
    }

    /// Human-readable label for a memory-pressure bucket.
    static func pressureLabel(for level: MemoryPressureLevel) -> String {
        switch level {
        case .nominal:
            return NSLocalizedString(
                "MemoryPressure.Nominal",
                comment: "Label for nominal memory pressure"
            )
        case .fair:
            return NSLocalizedString(
                "MemoryPressure.Fair",
                comment: "Label for fair memory pressure"
            )
        case .critical:
            return NSLocalizedString(
                "MemoryPressure.Critical",
                comment: "Label for critical memory pressure"
            )
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
        let format = NSLocalizedString(
            "%@ / %@",
            comment: "Format for used / total bytes, for example 8 GB / 16 GB"
        )
        return String(format: format, used, total)
    }

    private static func percentString(_ value: Double) -> String {
        let clamped = unitRatio(value)
        return percentFormatter.string(from: NSNumber(value: clamped)) ?? "\(Int((clamped * 100).rounded()))%"
    }

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        f.roundingMode = .halfUp
        return f
    }()

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
