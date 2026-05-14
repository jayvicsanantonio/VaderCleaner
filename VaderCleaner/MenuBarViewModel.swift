// MenuBarViewModel.swift
// View-model backing the menu bar extra — formats SystemStatsService values into menu-bar-ready strings and a compact label for `MenuBarExtra`.

import Foundation
import Combine

/// Drives the `MenuBarExtra` label and popover.
///
/// The view-model wraps a `SystemStatsService` (the same app-scope instance
/// the Health Monitor consumes) and exposes formatted display strings the
/// popover and label render. All formatting is exposed as `static` pure
/// functions so unit tests can pin the rules without instantiating a service
/// or driving real telemetry; instance properties forward live service state
/// through those formatters.
///
/// SwiftUI does not propagate a nested `ObservableObject`'s `objectWillChange`
/// through an outer `ObservableObject` automatically — without an explicit
/// Combine bridge in `init`, the popover would freeze on its first frame.
/// `serviceCancellable` retains the bridge subscription for the lifetime of
/// the view-model so each 2-second service tick fans out as a single VM
/// change.
@MainActor
final class MenuBarViewModel: ObservableObject {

    /// Live data source. Held strongly. The service is app-scope
    /// (`VaderCleanerApp.systemStats`) and outlives every consumer derived
    /// from it, so the strong reference does not extend its lifetime.
    let service: SystemStatsService

    /// Combine subscription that re-publishes service ticks as view-model
    /// changes. Stored so the sink lives as long as the VM does; without
    /// retaining the cancellable the subscription would be torn down at the
    /// end of `init` and the popover would freeze on its first frame.
    private var serviceCancellable: AnyCancellable?

    init(service: SystemStatsService) {
        self.service = service
        self.serviceCancellable = service.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Live-bound display values

    var formattedRAMUsage: String { Self.formattedRAMUsage(service.ramUsage) }
    var formattedDiskSpace: String { Self.formattedDiskSpace(service.diskSpace) }
    var formattedCPU: String { Self.formattedCPU(service.cpuUsage) }
    var formattedBatteryHealth: String? { Self.formattedBatteryHealth(service.batteryAvailability) }
    var ramPressureLevel: MemoryPressureLevel { service.ramUsage.pressureLevel }
    var ramPressureLabel: String { Self.pressureLabel(for: ramPressureLevel) }
    var ramPressureColor: StatusColor { Self.pressureColor(for: ramPressureLevel) }

    /// Single string the `MenuBarExtra` label renders. The format lives on the
    /// view-model (rather than as a `Text("RAM: \(...) | Disk: \(...)")`
    /// interpolation in the App scene) so the truncation rules in
    /// `menuBarLabel(ram:disk:)` are the only path producing menu bar text —
    /// no second copy of the format to keep in sync.
    var menuBarLabelText: String {
        Self.menuBarLabel(ram: service.ramUsage, disk: service.diskSpace)
    }

    // MARK: - Pure formatters

    /// Formats `MemoryStats` to `"used / total"` in GB. We force the GB unit
    /// (rather than letting `ByteCountFormatter` pick) so 8 GB never renders
    /// as "8,000 MB" on a non-en locale and so the popover row width stays
    /// stable across ticks.
    static func formattedRAMUsage(_ stats: MemoryStats) -> String {
        SystemStatsFormatters.memoryUsageString(stats)
    }

    /// Formats `DiskStats` to `"used / total · NN% free"`. Free percent is
    /// derived from `(total - used) / total`; rounded to integer so a noisy
    /// reading doesn't visually thrash with decimals.
    static func formattedDiskSpace(_ stats: DiskStats) -> String {
        let used = SystemStatsFormatters.byteString(stats.usedBytes)
        let total = SystemStatsFormatters.byteString(stats.totalBytes)
        let freePercent = freePercentInt(stats)
        return "\(used) / \(total) · \(freePercent)% free"
    }

    /// Formats a unit-interval CPU usage to an integer percentage. Inputs
    /// outside `[0, 1]` clamp at the boundary — matches
    /// `HealthMonitorViewModel.cpuPercentString` so both consumers display
    /// the same value for the same reading.
    static func formattedCPU(_ usage: Double) -> String {
        SystemStatsFormatters.cpuPercentString(usage)
    }

    /// Formats a present battery's `maxCapacityPercent` (0.0–1.0) as an
    /// integer percent. Returns `nil` when battery state is unknown or absent
    /// so the popover hides the row until there is a definitive battery to
    /// show.
    static func formattedBatteryHealth(_ availability: BatteryAvailability) -> String? {
        guard case .present(let stats) = availability else { return nil }
        return SystemStatsFormatters.batteryCapacityString(stats)
    }

    /// Human-readable label for a memory-pressure bucket. Matches the
    /// `HealthMonitorViewModel` vocabulary so the badge in the popover and
    /// the badge in the Health Monitor card always read the same way.
    static func pressureLabel(for level: MemoryPressureLevel) -> String {
        SystemStatsFormatters.pressureLabel(for: level)
    }

    /// Color for a memory-pressure bucket. Uses the shared system-stat
    /// palette so the menu bar and Health Monitor can never drift apart.
    static func pressureColor(for level: MemoryPressureLevel) -> StatusColor {
        SystemStatsFormatters.pressureColor(for: level)
    }

    // MARK: - Compact menu bar label

    /// Builds the single string `MenuBarExtra` renders. Uses compact GB
    /// values so even at full hardware ranges (256 GB RAM, 16 TB disk) the
    /// label stays well under the system menu bar's available width.
    ///
    /// Each segment is hard-capped via `clampedGB` so a buggy upstream
    /// reading of `UInt64.max` bytes can't render as `"18,446,744,073 GB"`
    /// and blow up label width.
    static func menuBarLabel(ram: MemoryStats, disk: DiskStats) -> String {
        let ramSegment = clampedGB(ram.usedBytes)
        // Disk segment shows free space in GB — that's the number the user
        // cares about at-a-glance ("how much room do I have left?"), and it
        // matches the `0 GB free` placeholder convention from Prompt 5 so
        // the label width doesn't jump on first real refresh.
        let freeBytes = disk.totalBytes > disk.usedBytes
            ? disk.totalBytes - disk.usedBytes
            : 0
        let diskSegment = clampedGB(freeBytes)
        return "RAM: \(ramSegment) · Disk: \(diskSegment) free"
    }

    // MARK: - Helpers

    /// Renders a byte count as compact GB ("12 GB"), capping the integer
    /// component at `compactGBCap` so absurd inputs render as "9999+ GB"
    /// rather than blowing up the menu bar label. Realistic Mac hardware
    /// (256 GB RAM, 16 TB disk = 16384 GB) sits well under the cap.
    ///
    /// Rounds to the nearest GB rather than truncating so the label tracks
    /// `ByteCountFormatter`'s rounding in the popover row — without this a
    /// reading of 7.9 GB would render as "7 GB" in the menu bar but "8 GB"
    /// in the popover, looking like a bug.
    private static func clampedGB(_ bytes: UInt64) -> String {
        // Saturate at Int64.max before the divide — `UInt64.max / 1e9` would
        // overflow Int otherwise. Saturate again before adding the half-GB
        // round-up bias so the addition itself can't overflow on inputs near
        // `UInt64.max`.
        let saturated = min(bytes, UInt64(Int64.max) - bytesPerGB)
        let gb = Int((saturated + bytesPerGB / 2) / bytesPerGB)
        if gb > compactGBCap {
            return "\(compactGBCap)+ GB"
        }
        return "\(gb) GB"
    }

    /// File-style GB (decimal, matching `ByteCountFormatter.countStyle = .file`).
    private static let bytesPerGB: UInt64 = 1_000_000_000

    /// Soft cap on integer GB rendered in the compact menu bar label. 99,999
    /// (~100 TB) sits comfortably above realistic Mac hardware — a 16 TB
    /// boot volume reads as 16,384 GB and renders as the live value, not the
    /// cap — so this only catches truly absurd readings (e.g. `UInt64.max`
    /// bytes from a buggy upstream). Keeps each segment to at most
    /// "99999+ GB" = 9 chars; combined label stays well under 50 chars.
    private static let compactGBCap = 99_999

    /// `(total - used) / total * 100` rounded to int. Returns `0` for
    /// zero-total state so the pre-first-refresh popover renders
    /// `"0 GB / 0 GB · 0% free"` rather than NaN.
    private static func freePercentInt(_ stats: DiskStats) -> Int {
        guard stats.totalBytes > 0 else { return 0 }
        let free = stats.totalBytes > stats.usedBytes
            ? stats.totalBytes - stats.usedBytes
            : 0
        let ratio = Double(free) / Double(stats.totalBytes)
        return Int((max(0.0, min(1.0, ratio)) * 100).rounded())
    }
}
