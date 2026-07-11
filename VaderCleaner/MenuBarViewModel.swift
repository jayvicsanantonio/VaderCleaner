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

    /// Used fraction of the boot volume for the storage tile's capacity bar.
    var diskUsedFraction: Double { Self.diskUsedFraction(service.diskSpace) }

    /// Raw disk snapshot, exposed so the view can feed the pure
    /// `recommendation` derivation alongside malware state it owns.
    var diskStats: DiskStats { service.diskSpace }

    /// Live charge snapshot for the battery tile, or `nil` when there is no
    /// internal battery.
    var batteryCharge: BatteryCharge? { service.batteryCharge }

    /// Battery tile SF Symbol tracking the live charge level.
    var batterySymbolName: String { Self.batterySymbolName(service.batteryCharge) }

    /// Battery tile status dot, or `nil` without a battery.
    var batteryStatusColor: StatusColor? { Self.batteryStatusColor(service.batteryCharge) }

    /// CPU tile status dot for the live load.
    var cpuLoadColor: StatusColor { Self.cpuLoadColor(service.cpuUsage) }

    /// Download throughput for the network tile, e.g. "513 bytes/s".
    var networkDownString: String { Self.speedString(service.networkThroughput.bytesInPerSec) }

    /// Upload throughput for the network tile.
    var networkUpString: String { Self.speedString(service.networkThroughput.bytesOutPerSec) }

    /// Wi-Fi network name for the network tile title, or a generic "Wi-Fi" when
    /// the SSID is unavailable (not on Wi-Fi, or Location not yet authorized).
    var wifiNetworkName: String { service.wifiSSID ?? String(localized: "Wi-Fi") }

    /// CPU temperature for the CPU tile, or `nil` when the SMC reports none on
    /// this hardware (the tile hides the value rather than showing a guess).
    var cpuTemperature: String? {
        service.cpuTemperatureCelsius.map(Self.cpuTemperatureString)
    }

    /// System uptime for the CPU tile, e.g. "up 3d 4h".
    var systemUptimeString: String { Self.uptimeString(service.systemUptime) }

    // MARK: - Speed test

    /// State of the on-demand connection speed test the network tile triggers.
    enum SpeedTestState: Equatable {
        case idle
        case running
        case result(downloadMbps: Double)
        case failed
    }

    private(set) var speedTestState: SpeedTestState = .idle

    /// Cloudflare's public download endpoint, used to measure real throughput.
    private static let speedTestURL = URL(string: "https://speed.cloudflare.com/__down?bytes=10000000")!

    /// Runs a real download speed test and publishes the result. Idempotent
    /// while a test is in flight. Any failure (offline, non-2xx) resolves to
    /// `.failed` so the tile can offer a retry rather than hang.
    func runSpeedTest() async {
        guard speedTestState != .running else { return }
        speedTestState = .running
        let start = Date()
        do {
            var request = URLRequest(url: Self.speedTestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                speedTestState = .failed
                return
            }
            let seconds = Date().timeIntervalSince(start)
            speedTestState = .result(downloadMbps: Self.megabitsPerSecond(bytes: data.count, seconds: seconds))
        } catch {
            speedTestState = .failed
        }
    }

    /// Single string the `MenuBarExtra` label renders. The format lives on the
    /// view-model (rather than as a `Text("RAM: \(...) | Disk: \(...)")`
    /// interpolation in the App scene) so the truncation rules in
    /// `menuBarLabel(ram:disk:)` are the only path producing menu bar text —
    /// no second copy of the format to keep in sync.
    var menuBarLabelText: String {
        Self.menuBarLabel(ram: service.ramUsage, disk: service.diskSpace)
    }

    /// A short reading shown beside the menu bar icon when the user opts in —
    /// free disk space, the most glanceable single number, kept narrow so it is
    /// far less prone to being hidden behind the notch than the full label.
    var menuBarCompactReading: String { Self.availableDiskString(service.diskSpace) }

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

    /// Free space on the boot volume, e.g. "670 GB" — the number the storage
    /// tile leads with ("how much room is left?"). Rounds to whole GB: decimal
    /// precision is noise at menu-glance size and would thrash across the
    /// 2-second refresh. Below one GB it falls back to the shared byte
    /// formatter ("0.5 GB") so a nearly-full disk doesn't read as a useless
    /// "0 GB".
    static func availableDiskString(_ stats: DiskStats) -> String {
        let free = stats.totalBytes > stats.usedBytes ? stats.totalBytes - stats.usedBytes : 0
        guard free >= bytesPerGB else { return SystemStatsFormatters.byteString(free) }
        let measurement = Measurement(value: Double(free), unit: UnitInformationStorage.bytes)
            .converted(to: .gigabytes)
        return wholeGBFormatter.string(from: measurement)
    }

    /// Allocated once, like `relativeFormatter`: formatter construction is not
    /// cheap enough for a per-render rebuild on the 2-second refresh.
    private static let wholeGBFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    /// Used portion of the boot volume as a unit fraction, clamped to 0…1 —
    /// drives the storage tile's capacity bar. `0` for the zero-total
    /// pre-first-refresh state rather than NaN.
    static func diskUsedFraction(_ stats: DiskStats) -> Double {
        guard stats.totalBytes > 0 else { return 0 }
        let ratio = Double(stats.usedBytes) / Double(stats.totalBytes)
        return max(0.0, min(1.0, ratio))
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

    /// SF Symbol for the battery tile, tracking the real charge level instead
    /// of a hardcoded full battery. Charging shows the bolt variant; the
    /// no-battery fallback pairs with the tile's "No battery" text. Levels
    /// bucket to the nearest of SF Symbols' five battery steps.
    static func batterySymbolName(_ charge: BatteryCharge?) -> String {
        guard let charge else { return "battery.100percent" }
        if charge.isCharging { return "battery.100percent.bolt" }
        switch charge.percent {
        case ..<13:   return "battery.0percent"
        case ..<38:   return "battery.25percent"
        case ..<63:   return "battery.50percent"
        case ..<88:   return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    /// Status dot for the battery tile, matching the memory tile's traffic
    /// lights: green while charging or comfortable, yellow when low, red when
    /// nearly empty. `nil` (no dot) without a battery.
    static func batteryStatusColor(_ charge: BatteryCharge?) -> StatusColor? {
        guard let charge else { return nil }
        if charge.isCharging { return .green }
        switch charge.percent {
        case ..<10:  return .red
        case ..<20:  return .yellow
        default:     return .green
        }
    }

    /// Status dot for the CPU tile: comfortable under 70% load, busy under
    /// 90%, saturated above.
    static func cpuLoadColor(_ usage: Double) -> StatusColor {
        switch usage {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default:     return .red
        }
    }

    /// Formats a bytes-per-second rate for the network tile, e.g. "2 KB/s".
    /// Zero traffic renders "0 KB/s" rather than `ByteCountFormatter`'s
    /// locale-specific "Zero KB".
    static func speedString(_ bytesPerSec: Double) -> String {
        let bytes = max(0, bytesPerSec)
        guard bytes >= 1 else { return "0 KB/s" }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(formatted)/s"
    }

    /// Download megabits-per-second from a payload size and elapsed seconds.
    static func megabitsPerSecond(bytes: Int, seconds: Double) -> Double {
        guard seconds > 0, bytes > 0 else { return 0 }
        return (Double(bytes) * 8.0 / 1_000_000.0) / seconds
    }

    /// Formats a speed-test result, e.g. "82 Mbps".
    static func speedTestResultString(_ mbps: Double) -> String {
        String(format: "%.0f Mbps", mbps)
    }

    /// CPU temperature rounded to a whole degree, e.g. "50°C".
    static func cpuTemperatureString(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°C"
    }

    // MARK: - Protection

    /// Malware-protection status for the menu's Protection card.
    enum ProtectionStatus: Equatable {
        case protected
        case threatsFound
        case notScanned
        case scanning
    }

    /// Which scanner is currently driving the card's `.scanning` state. The
    /// card renames itself to match, so the popup never claims a threat check
    /// while the main window is visibly sweeping junk.
    enum ScanActivity: Equatable {
        /// Smart Scan is running (junk, large files, and threats in one pass).
        case smartScan
        /// Protection's own scanner is running (threats only).
        case threatScan
    }

    /// Card title for the current activity. "Smart Scan" is the card's
    /// resting identity — it reports the last scan and launches the next one
    /// — so the title only changes while Protection's threat-only scanner is
    /// what's actually running.
    static func protectionCardTitle(for activity: ScanActivity?) -> String {
        switch activity {
        case .smartScan, nil:
            return String(localized: "Smart Scan", comment: "Scan card title.")
        case .threatScan:
            return String(localized: "Threat Scan", comment: "Scan card title while a threat-only scan is running.")
        }
    }

    /// Detail line while a scan runs, naming what that scan actually covers.
    static func scanningDetail(for activity: ScanActivity) -> String {
        switch activity {
        case .smartScan:
            return String(
                localized: "Looking for junk, large files, and threats…",
                comment: "Protection card detail while Smart Scan is running."
            )
        case .threatScan:
            return String(
                localized: "Checking this Mac for threats…",
                comment: "Protection card detail while a threat scan is running."
            )
        }
    }

    /// Derives protection status from the malware scan state: a scan in
    /// flight outranks everything (the card narrates the activity instead of
    /// showing stale results), then threats; otherwise a Mac that has been
    /// scanned at least once reads as protected, and one that never has reads
    /// as not-yet-scanned.
    static func protectionStatus(hasThreats: Bool, hasScanned: Bool, isScanning: Bool = false) -> ProtectionStatus {
        if isScanning { return .scanning }
        if hasThreats { return .threatsFound }
        return hasScanned ? .protected : .notScanned
    }

    /// Short status label for the Protection card.
    static func protectionStatusLabel(_ status: ProtectionStatus) -> String {
        switch status {
        case .protected:
            return String(localized: "Protected", comment: "Protection card status when the last scan was clean.")
        case .threatsFound:
            return String(localized: "Threats found", comment: "Protection card status when threats are present.")
        case .notScanned:
            return String(localized: "Not scanned", comment: "Protection card status when no scan has run yet.")
        case .scanning:
            return String(localized: "Scanning…", comment: "Protection card status while a scan is running.")
        }
    }

    /// Allocated once: `RelativeDateTimeFormatter` carries per-instance state, so
    /// reusing one avoids rebuilding it on each Protection-card refresh.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "Last scan 3 days ago" / "No scans yet" detail for the Protection card.
    static func lastScanString(_ date: Date?) -> String {
        guard let date else {
            return String(localized: "No scans yet", comment: "Protection card detail when no scan has run.")
        }
        let relative = relativeFormatter.localizedString(for: date, relativeTo: Date())
        let format = String(localized: "Last scan %@", comment: "Protection card detail; %@ is a relative date.")
        return String(format: format, relative)
    }

    // MARK: - Recommendation

    /// One state-driven suggestion for the panel's "Today's Recommendation"
    /// card: what to say, what the button reads, and where it deep-links.
    struct Recommendation: Equatable {
        /// Destination the card's action deep-links to. A view-model-local
        /// enum (rather than `NavigationSection`) keeps this type framework-
        /// free and pinnable in unit tests; the view maps it to a section.
        enum Target: Equatable {
            case smartScan
            case cleanup
            case performance
        }

        let title: String
        let message: String
        let actionLabel: String
        let target: Target
        /// Whether the deep-link should also start the target's scan.
        let startsScan: Bool
    }

    /// Free-space fraction below which the disk counts as running low.
    private static let lowDiskFreeThreshold = 0.10

    /// Last-scan age beyond which a protected Mac is nudged to scan again.
    private static let staleScanInterval: TimeInterval = 7 * 86_400

    /// Derives the recommendation card's content from live panel state.
    ///
    /// Priority: a nearly-full disk outranks everything (it is the one state
    /// a cleaner app must never sit on), then critical memory pressure, then
    /// scan hygiene. Returns `nil` when protection is unscanned or has live
    /// threats and nothing else is urgent — in those states the Protection
    /// card carries the scan CTA, and repeating it here would just add noise.
    static func recommendation(
        protection: ProtectionStatus,
        disk: DiskStats,
        pressure: MemoryPressureLevel,
        lastScanDate: Date?,
        now: Date = Date()
    ) -> Recommendation? {
        if disk.totalBytes > 0, 1.0 - diskUsedFraction(disk) < lowDiskFreeThreshold {
            return Recommendation(
                title: String(localized: "Storage is running low",
                              comment: "Recommendation title when free disk space is under 10%."),
                message: String(localized: "Less than 10% of your disk is free. Clear out junk to reclaim space.",
                                comment: "Recommendation message when free disk space is under 10%."),
                actionLabel: String(localized: "Clean Up",
                                    comment: "Recommendation button that opens the Cleanup section."),
                target: .cleanup,
                startsScan: false
            )
        }
        if pressure == .critical {
            return Recommendation(
                title: String(localized: "Memory pressure is critical",
                              comment: "Recommendation title when memory pressure is critical."),
                message: String(localized: "Your Mac is low on memory. Free some up to keep apps responsive.",
                                comment: "Recommendation message when memory pressure is critical."),
                actionLabel: String(localized: "Free Memory",
                                    comment: "Recommendation button that opens the Performance section."),
                target: .performance,
                startsScan: false
            )
        }
        guard protection == .protected else { return nil }
        if lastScanDate.map({ now.timeIntervalSince($0) > staleScanInterval }) ?? true {
            return Recommendation(
                title: String(localized: "Time for a fresh scan",
                              comment: "Recommendation title when the last scan is over a week old."),
                message: String(localized: "It's been over a week since your last Smart Scan.",
                                comment: "Recommendation message when the last scan is over a week old."),
                actionLabel: String(localized: "Run Smart Scan",
                                    comment: "Recommendation button that starts a Smart Scan."),
                target: .smartScan,
                startsScan: true
            )
        }
        return Recommendation(
            title: String(localized: "You're all set",
                          comment: "Recommendation title when nothing needs attention."),
            message: String(localized: "No issues need your attention. A periodic Smart Scan keeps it that way.",
                            comment: "Recommendation message when nothing needs attention."),
            actionLabel: String(localized: "Run Smart Scan",
                                comment: "Recommendation button that starts a Smart Scan."),
            target: .smartScan,
            startsScan: true
        )
    }

    /// Compact uptime, e.g. "up 3d 4h", "up 4h 12m", or "up 8m". Drops to the
    /// two most significant units so the CPU tile stays one short line.
    static func uptimeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let value: String
        if days > 0 {
            value = "\(days)d \(hours)h"
        } else if hours > 0 {
            value = "\(hours)h \(minutes)m"
        } else {
            value = "\(minutes)m"
        }
        let format = String(localized: "up %@", comment: "CPU tile uptime line; %@ is a duration like 3d 4h")
        return String(format: format, value)
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
