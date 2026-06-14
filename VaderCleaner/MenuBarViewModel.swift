// MenuBarViewModel.swift
// View-model backing the menu bar extra — formats SystemStatsService values into menu-bar-ready strings and a compact label for `MenuBarExtra`.

import Foundation
import Observation

/// Drives the `MenuBarExtra` label and popover.
///
/// The view-model wraps a `SystemStatsService` (the same app-scope instance
/// the Health Monitor consumes) and exposes formatted display strings the
/// popover and label render. All formatting is exposed as `static` pure
/// functions so unit tests can pin the rules without instantiating a service
/// or driving real telemetry; instance properties forward live service state
/// through those formatters.
///
/// No Combine bridge: under the Observation framework SwiftUI tracks the
/// read chain `view → vm.someComputed → service.someProperty` transparently,
/// so each 2-second service tick directly invalidates any view reading the
/// matching computed property here.
@MainActor
@Observable
final class MenuBarViewModel {

    /// Live data source. Held strongly. The service is app-scope
    /// (`VaderCleanerApp.systemStats`) and outlives every consumer derived
    /// from it, so the strong reference does not extend its lifetime.
    let service: SystemStatsService

    init(service: SystemStatsService) {
        self.service = service
    }

    /// Boot-volume display name ("Macintosh HD"), resolved once — it never
    /// changes for the life of the view-model and the storage tile shows it on
    /// every render.
    let bootVolumeName: String = HealthMonitorViewModel.rootVolumeName()

    // MARK: - Live-bound display values

    var formattedRAMUsage: String { Self.formattedRAMUsage(service.ramUsage) }
    var formattedDiskSpace: String { Self.formattedDiskSpace(service.diskSpace) }
    var formattedCPU: String { Self.formattedCPU(service.cpuUsage) }
    var formattedBatteryHealth: String? { Self.formattedBatteryHealth(service.batteryAvailability) }
    var ramPressureLevel: MemoryPressureLevel { service.ramUsage.pressureLevel }
    var ramPressureLabel: String { Self.pressureLabel(for: ramPressureLevel) }
    var ramPressureColor: StatusColor { Self.pressureColor(for: ramPressureLevel) }

    // MARK: - Menu panel values

    /// The Mac's name (e.g. "Jayvic's MacBook Pro"), shown under the Mac Health
    /// verdict in the panel header. Falls back to "Mac" if the name is unset.
    var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// Overall Mac Health verdict for the panel header, reusing the Health
    /// Monitor's problem-based derivation so the menu and the main window never
    /// disagree. `nil` while the boot volume is still being measured.
    var macHealth: MacHealthStatus? {
        HealthMonitorViewModel.macHealthStatus(
            disk: service.diskSpace,
            smart: service.diskSMARTStatus,
            battery: service.batteryAvailability
        )
    }

    /// Free space on the boot volume — the storage tile's headline number.
    var availableDiskSpace: String { Self.availableDiskString(service.diskSpace) }

    /// Memory in use as a whole percentage — the memory tile's headline number.
    var memoryUsedPercent: String { Self.memoryUsedPercentString(service.ramUsage) }

    /// Live charge snapshot for the battery tile, or `nil` when there is no
    /// internal battery.
    var batteryCharge: BatteryCharge? { service.batteryCharge }

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
        let usage = SystemStatsFormatters.diskUsageString(stats)
        let freePercent = freePercentInt(stats)
        let format = NSLocalizedString(
            "%@ · %d%% free",
            comment: "Format for disk usage and percent free, for example 250 GB / 500 GB · 50% free"
        )
        return String(format: format, usage, freePercent)
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

    /// Free space on the boot volume, e.g. "434.3 GB" — the number the storage
    /// tile leads with ("how much room is left?").
    static func availableDiskString(_ stats: DiskStats) -> String {
        let free = stats.totalBytes > stats.usedBytes ? stats.totalBytes - stats.usedBytes : 0
        return SystemStatsFormatters.byteString(free)
    }

    /// Memory in use as a whole percentage, clamped to 0…100. `0%` for the
    /// zero-total pre-first-refresh state rather than NaN.
    static func memoryUsedPercentString(_ stats: MemoryStats) -> String {
        guard stats.totalBytes > 0 else { return "0%" }
        let ratio = Double(stats.usedBytes) / Double(stats.totalBytes)
        return "\(Int((max(0.0, min(1.0, ratio)) * 100).rounded()))%"
    }

    /// Current charge as a whole percentage, e.g. "100%".
    static func batteryChargeString(_ charge: BatteryCharge) -> String {
        "\(charge.percent)%"
    }

    /// Plain-language power state for the battery tile's subtitle.
    static func batteryStateString(_ charge: BatteryCharge) -> String {
        if charge.isCharging {
            return String(localized: "Charging", comment: "Battery tile subtitle while charging.")
        }
        if charge.percent >= 100 && charge.isPluggedIn {
            return String(localized: "Fully Charged", comment: "Battery tile subtitle when full and on AC.")
        }
        if charge.isPluggedIn {
            return String(localized: "Plugged In", comment: "Battery tile subtitle on AC but not charging.")
        }
        return String(localized: "On Battery", comment: "Battery tile subtitle while discharging.")
    }

    /// Battery temperature rounded to a whole degree, e.g. "30°C".
    static func batteryTemperatureString(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°C"
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
