// MenuBarViewModelTests.swift
// Tests that MenuBarViewModel formats SystemStatsService values into menu-bar-ready strings and bridges service ticks to the popover.

import XCTest
import Observation
@testable import VaderCleaner

@MainActor
final class MenuBarViewModelTests: XCTestCase {

    // MARK: - RAM formatting

    /// `formattedRAMUsage` is the popover row's value. The service publishes
    /// `MemoryStats` in bytes; the popover wants a `"used / total"` GB string
    /// so the user can see headroom at a glance.
    func test_formattedRAMUsage_formatsBytesToGB() {
        let stats = MemoryStats(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000)
        let formatted = MenuBarViewModel.formattedRAMUsage(stats)
        XCTAssertTrue(formatted.contains("8"), "Expected used GB in output, got \(formatted)")
        XCTAssertTrue(formatted.contains("16"), "Expected total GB in output, got \(formatted)")
        XCTAssertTrue(formatted.contains("/"), "Expected used/total separator, got \(formatted)")
    }

    /// Pre-first-refresh state is `MemoryStats.empty` (all zeros). The
    /// formatter must still produce a non-empty string so the popover row
    /// always has *something* to render.
    func test_formattedRAMUsage_handlesZeroTotal() {
        XCTAssertFalse(MenuBarViewModel.formattedRAMUsage(.empty).isEmpty)
    }

    // MARK: - Disk formatting

    /// `formattedDiskSpace` returns `"used / total · NN% free"` so the popover
    /// surfaces both absolute capacity and remaining headroom in one row.
    func test_formattedDiskSpace_formatsBytesToGBWithFreePercent() {
        // 250 GB used / 500 GB total → 50% free.
        let stats = DiskStats(usedBytes: 250_000_000_000, totalBytes: 500_000_000_000)
        let formatted = MenuBarViewModel.formattedDiskSpace(stats)
        XCTAssertTrue(formatted.contains("250"), "Expected used GB in output, got \(formatted)")
        XCTAssertTrue(formatted.contains("500"), "Expected total GB in output, got \(formatted)")
        // Match the full token rather than `contains("50")` — the latter
        // would already pass on the `"500"` total and silently let a wrong
        // free-percent slip through.
        XCTAssertTrue(formatted.contains("50% free"), "Expected '50% free' in output, got \(formatted)")
    }

    /// Zero-total state must not divide by zero and must still render.
    func test_formattedDiskSpace_handlesZeroTotal() {
        XCTAssertFalse(MenuBarViewModel.formattedDiskSpace(.empty).isEmpty)
    }

    // MARK: - CPU formatting

    /// CPU value goes in the popover as an integer percent — the menu bar is
    /// not the place for two-decimal precision.
    func test_formattedCPU_formatsAsPercent() {
        XCTAssertEqual(MenuBarViewModel.formattedCPU(0.0), "0%")
        XCTAssertEqual(MenuBarViewModel.formattedCPU(0.42), "42%")
        XCTAssertEqual(MenuBarViewModel.formattedCPU(1.0), "100%")
    }

    /// Out-of-range inputs clamp rather than rendering `"-3%"` or `"137%"`.
    /// The service already clamps internally; this is the last line of
    /// defence and matches `HealthMonitorViewModel.cpuPercentString` semantics.
    func test_formattedCPU_clampsOutOfRangeInputs() {
        XCTAssertEqual(MenuBarViewModel.formattedCPU(-0.5), "0%")
        XCTAssertEqual(MenuBarViewModel.formattedCPU(2.0), "100%")
    }

    // MARK: - Battery formatting

    /// Battery row shows max-capacity percent — same shape as
    /// `HealthMonitorViewModel.batteryCapacityString` but pulled through
    /// `MenuBarViewModel` so tests pin the menu bar's contract independently.
    func test_formattedBatteryHealth_formatsAsPercent() {
        let stats = BatteryStats(cycleCount: 100, maxCapacityPercent: 0.95, condition: "Good")
        XCTAssertEqual(MenuBarViewModel.formattedBatteryHealth(.present(stats)), "95%")
    }

    /// Startup and desktop/no-battery states should not render a misleading
    /// empty Battery row in the compact popover.
    func test_formattedBatteryHealth_isNilWhenUnknownOrAbsent() {
        XCTAssertNil(MenuBarViewModel.formattedBatteryHealth(.unknown))
        XCTAssertNil(MenuBarViewModel.formattedBatteryHealth(.absent))
    }

    // MARK: - Pressure indicator

    func test_pressureLabel_returnsHumanReadable() {
        XCTAssertEqual(MenuBarViewModel.pressureLabel(for: .nominal), "Normal")
        XCTAssertEqual(MenuBarViewModel.pressureLabel(for: .fair), "Fair")
        XCTAssertEqual(MenuBarViewModel.pressureLabel(for: .critical), "Critical")
    }

    func test_pressureColor_mapsLevelsToTrafficLights() {
        XCTAssertEqual(MenuBarViewModel.pressureColor(for: .nominal), .green)
        XCTAssertEqual(MenuBarViewModel.pressureColor(for: .fair), .yellow)
        XCTAssertEqual(MenuBarViewModel.pressureColor(for: .critical), .red)
    }

    // MARK: - Menu bar label

    /// The compact label is what `MenuBarExtra` renders to the system menu
    /// bar. It bundles RAM and disk into a single string so the App scene can
    /// stay declarative — `Text(viewModel.menuBarLabelText)` rather than a
    /// hand-built interpolation.
    func test_menuBarLabel_combinesRAMandDiskWithBothPrefixes() {
        let ram = MemoryStats(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000)
        let disk = DiskStats(usedBytes: 250_000_000_000, totalBytes: 500_000_000_000)
        let label = MenuBarViewModel.menuBarLabel(ram: ram, disk: disk)
        XCTAssertTrue(label.contains("RAM"), "Expected RAM prefix, got \(label)")
        XCTAssertTrue(label.contains("Disk"), "Expected Disk prefix, got \(label)")
        XCTAssertTrue(label.contains("8"), "Expected used RAM GB in label, got \(label)")
        XCTAssertTrue(label.contains("250"), "Expected free disk GB in label, got \(label)")
    }

    /// Critical robustness check: a buggy upstream reading of `UInt64.max`
    /// bytes would render as `"18,446,744,073 GB"` through a naive
    /// `ByteCountFormatter`, blowing up the menu bar label width. The label
    /// builder must clamp each segment so the rendered text stays bounded.
    /// 50 chars is generous for the system menu bar — real readings cap at
    /// roughly `"RAM: 256 GB · Disk: 16384 GB free"` (~36 chars).
    ///
    /// Disk uses `usedBytes: 0, totalBytes: UInt64.max` so the *free* space
    /// (the segment the label renders) is also extreme — `usedBytes ==
    /// totalBytes` would have rendered `0 GB free` and silently bypassed
    /// the disk-side clamp.
    func test_menuBarLabel_truncatesGracefullyForLargeValues() {
        let extreme = MemoryStats(usedBytes: UInt64.max, totalBytes: UInt64.max)
        let extremeDisk = DiskStats(usedBytes: 0, totalBytes: UInt64.max)
        let label = MenuBarViewModel.menuBarLabel(ram: extreme, disk: extremeDisk)
        XCTAssertTrue(
            label.contains("RAM: 99999+ GB"),
            "Expected RAM segment to be capped, got \(label)"
        )
        XCTAssertTrue(
            label.contains("Disk: 99999+ GB free"),
            "Expected disk segment to be capped, got \(label)"
        )
        XCTAssertLessThanOrEqual(
            label.count, 50,
            "Menu bar label must stay bounded for absurd inputs, got \(label.count) chars: \(label)"
        )
        // Pin that the raw integer never leaked into the label — proves the
        // bound was hit by clamping rather than incidentally short.
        XCTAssertFalse(
            label.contains(String(UInt64.max)),
            "Raw UInt64.max must not appear in label, got \(label)"
        )
    }

    /// Zero-total state at startup must still produce a renderable label —
    /// `MenuBarExtra` evaluates `label:` immediately, before the first refresh
    /// publishes real values.
    func test_menuBarLabel_handlesZeroTotals() {
        let label = MenuBarViewModel.menuBarLabel(ram: .empty, disk: .empty)
        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(label.contains("RAM"))
        XCTAssertTrue(label.contains("Disk"))
    }

    // MARK: - Service binding

    /// The view-model is constructed with a `SystemStatsService`. Constructing
    /// it with a non-autostarted service must not crash — exercises the
    /// production init path used via `@StateObject`.
    func test_initWithService_storesServiceReference() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        let sut = MenuBarViewModel(service: service)
        XCTAssertTrue(sut.service === service)
    }

    /// Under the Observation framework SwiftUI tracks the read chain
    /// `view → vm.formattedRAMUsage → service.ramUsage` transparently — no
    /// manual `objectWillChange` bridge is required. This test pins that
    /// invariant: registering tracking on the VM's computed property and
    /// then mutating the service via `refresh()` must invoke `onChange`,
    /// the same signal SwiftUI uses to re-render the popover.
    func test_servicePropertyChange_invalidatesViewModelDerivedReads() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        let sut = MenuBarViewModel(service: service)

        var fired = false
        withObservationTracking {
            _ = sut.formattedRAMUsage
        } onChange: {
            fired = true
        }

        // Drive a refresh — the service's tracked-property setters fire
        // Observation registrations on every view (or test) that read the
        // chain, so the popover re-renders without any extra wiring.
        service.refresh()

        XCTAssertTrue(
            fired,
            "Mutating service.ramUsage must invalidate views observing vm.formattedRAMUsage"
        )
    }

    /// Live-bound display values forward the service state through the pure
    /// formatters. Pinning instance ↔ static parity here means a future
    /// formatter change can't drift one consumer apart from the other.
    func test_liveBoundProperties_matchPureFormatters() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        let sut = MenuBarViewModel(service: service)

        XCTAssertEqual(sut.formattedRAMUsage, MenuBarViewModel.formattedRAMUsage(service.ramUsage))
        XCTAssertEqual(sut.formattedDiskSpace, MenuBarViewModel.formattedDiskSpace(service.diskSpace))
        XCTAssertEqual(sut.formattedCPU, MenuBarViewModel.formattedCPU(service.cpuUsage))
        XCTAssertEqual(sut.formattedBatteryHealth, MenuBarViewModel.formattedBatteryHealth(service.batteryAvailability))
        XCTAssertEqual(
            sut.menuBarLabelText,
            MenuBarViewModel.menuBarLabel(ram: service.ramUsage, disk: service.diskSpace)
        )
    }

    // MARK: - Menu panel formatters

    /// Available disk space is the free portion (total − used), formatted.
    func test_availableDiskString_isFreePortion() {
        let stats = DiskStats(usedBytes: 600_000_000_000, totalBytes: 1_000_000_000_000)
        let formatted = MenuBarViewModel.availableDiskString(stats)
        XCTAssertTrue(formatted.contains("400"), "Expected ~400 GB free, got \(formatted)")
    }

    /// Memory used percent is used/total, rounded and clamped.
    func test_memoryUsedPercentString_isUsedOverTotal() {
        let stats = MemoryStats(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000)
        XCTAssertEqual(MenuBarViewModel.memoryUsedPercentString(stats), "50%")
    }

    /// Zero-total memory (pre-first-refresh) renders 0%, not NaN.
    func test_memoryUsedPercentString_handlesZeroTotal() {
        XCTAssertEqual(MenuBarViewModel.memoryUsedPercentString(.empty), "0%")
    }

    /// Charge percent renders straight through.
    func test_batteryChargeString_rendersPercent() {
        let charge = BatteryCharge(percent: 100, isCharging: true, isPluggedIn: true,
                                   timeRemainingMinutes: nil, temperatureCelsius: nil)
        XCTAssertEqual(MenuBarViewModel.batteryChargeString(charge), "100%")
    }

    /// Power state copy covers charging, full-on-AC, plugged-not-charging, and
    /// discharging.
    func test_batteryStateString_coversPowerStates() {
        let charging = BatteryCharge(percent: 80, isCharging: true, isPluggedIn: true,
                                     timeRemainingMinutes: 30, temperatureCelsius: nil)
        XCTAssertEqual(MenuBarViewModel.batteryStateString(charging), "Charging")

        let full = BatteryCharge(percent: 100, isCharging: false, isPluggedIn: true,
                                 timeRemainingMinutes: nil, temperatureCelsius: nil)
        XCTAssertEqual(MenuBarViewModel.batteryStateString(full), "Fully Charged")

        let plugged = BatteryCharge(percent: 90, isCharging: false, isPluggedIn: true,
                                    timeRemainingMinutes: nil, temperatureCelsius: nil)
        XCTAssertEqual(MenuBarViewModel.batteryStateString(plugged), "Plugged In")

        let onBattery = BatteryCharge(percent: 64, isCharging: false, isPluggedIn: false,
                                      timeRemainingMinutes: 120, temperatureCelsius: nil)
        XCTAssertEqual(MenuBarViewModel.batteryStateString(onBattery), "On Battery")
    }

    /// Temperature rounds to a whole degree.
    func test_batteryTemperatureString_roundsToWholeDegree() {
        XCTAssertEqual(MenuBarViewModel.batteryTemperatureString(30.4), "30°C")
        XCTAssertEqual(MenuBarViewModel.batteryTemperatureString(30.6), "31°C")
    }

    // MARK: - Network formatters

    /// Zero traffic renders a clean "0 KB/s", not "Zero KB/s".
    func test_speedString_zeroIsCleanedUp() {
        XCTAssertEqual(MenuBarViewModel.speedString(0), "0 KB/s")
    }

    /// Non-zero rates carry a unit and a per-second suffix.
    func test_speedString_formatsRateWithSuffix() {
        let kilobytes = MenuBarViewModel.speedString(2_048)
        XCTAssertTrue(kilobytes.contains("KB"), "Expected KB unit, got \(kilobytes)")
        XCTAssertTrue(kilobytes.hasSuffix("/s"), "Expected /s suffix, got \(kilobytes)")

        let megabytes = MenuBarViewModel.speedString(5_000_000)
        XCTAssertTrue(megabytes.contains("MB"), "Expected MB unit, got \(megabytes)")
    }

    /// Mbps math: 10 MB downloaded in 8 s is 10 Mbps (10e6 bytes × 8 ÷ 1e6 ÷ 8).
    func test_megabitsPerSecond_computesRate() {
        XCTAssertEqual(MenuBarViewModel.megabitsPerSecond(bytes: 10_000_000, seconds: 8), 10, accuracy: 0.001)
    }

    /// Guard against divide-by-zero and empty payloads.
    func test_megabitsPerSecond_guardsZeroes() {
        XCTAssertEqual(MenuBarViewModel.megabitsPerSecond(bytes: 0, seconds: 5), 0)
        XCTAssertEqual(MenuBarViewModel.megabitsPerSecond(bytes: 1_000, seconds: 0), 0)
    }

    func test_speedTestResultString_formatsMbps() {
        XCTAssertEqual(MenuBarViewModel.speedTestResultString(82.4), "82 Mbps")
    }

    // MARK: - CPU temperature + uptime formatters

    func test_cpuTemperatureString_roundsToWholeDegree() {
        XCTAssertEqual(MenuBarViewModel.cpuTemperatureString(49.6), "50°C")
    }

    /// Uptime collapses to the two most significant units, by magnitude, and
    /// reads as plain language ("on for …") rather than server-style "up …".
    func test_uptimeString_picksTwoMostSignificantUnits() {
        XCTAssertEqual(MenuBarViewModel.uptimeString(3 * 86_400 + 4 * 3_600 + 30 * 60), "on for 3d 4h")
        XCTAssertEqual(MenuBarViewModel.uptimeString(4 * 3_600 + 12 * 60), "on for 4h 12m")
        XCTAssertEqual(MenuBarViewModel.uptimeString(8 * 60 + 30), "on for 8m")
    }

    /// The compact menu bar reading forwards to the available-disk formatter.
    func test_menuBarCompactReading_isAvailableDisk() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        let sut = MenuBarViewModel(service: service)
        XCTAssertEqual(sut.menuBarCompactReading, MenuBarViewModel.availableDiskString(service.diskSpace))
    }

    // MARK: - Protection status

    /// Threats outrank a clean history; a scanned-once Mac reads protected; a
    /// never-scanned Mac reads not-scanned.
    func test_protectionStatus_derivation() {
        XCTAssertEqual(MenuBarViewModel.protectionStatus(hasThreats: true, hasScanned: true), .threatsFound)
        XCTAssertEqual(MenuBarViewModel.protectionStatus(hasThreats: true, hasScanned: false), .threatsFound)
        XCTAssertEqual(MenuBarViewModel.protectionStatus(hasThreats: false, hasScanned: true), .protected)
        XCTAssertEqual(MenuBarViewModel.protectionStatus(hasThreats: false, hasScanned: false), .notScanned)
    }

    func test_protectionStatusLabel_copy() {
        XCTAssertEqual(MenuBarViewModel.protectionStatusLabel(.protected), "Protected")
        XCTAssertEqual(MenuBarViewModel.protectionStatusLabel(.threatsFound), "Threats found")
        XCTAssertEqual(MenuBarViewModel.protectionStatusLabel(.notScanned), "Not scanned")
        XCTAssertEqual(MenuBarViewModel.protectionStatusLabel(.scanning), "Scanning…")
    }

    /// A running scan outranks every other protection state — mid-scan the
    /// card must acknowledge the activity rather than keep claiming "Not
    /// scanned" or "Threats found" from stale results.
    func test_protectionStatus_scanningOutranksOtherStates() {
        XCTAssertEqual(
            MenuBarViewModel.protectionStatus(hasThreats: false, hasScanned: false, isScanning: true),
            .scanning
        )
        XCTAssertEqual(
            MenuBarViewModel.protectionStatus(hasThreats: true, hasScanned: true, isScanning: true),
            .scanning
        )
        // The default keeps the non-scanning derivation unchanged.
        XCTAssertEqual(
            MenuBarViewModel.protectionStatus(hasThreats: false, hasScanned: false),
            .notScanned
        )
    }

    /// The card reads "Smart Scan" — its resting identity and the scan it
    /// launches — and renames only while Protection's threat-only scanner is
    /// what's actually running, so the title never contradicts the activity.
    func test_protectionCardTitle_matchesTheRunningScan() {
        XCTAssertEqual(MenuBarViewModel.protectionCardTitle(for: .smartScan), "Smart Scan")
        XCTAssertEqual(MenuBarViewModel.protectionCardTitle(for: .threatScan), "Threat Scan")
        XCTAssertEqual(MenuBarViewModel.protectionCardTitle(for: nil), "Smart Scan")
    }

    /// The scanning detail line names what the running scan actually covers:
    /// Smart Scan checks junk, large files, and threats; Protection's own
    /// scanner checks threats only.
    func test_scanningDetail_describesTheRunningScan() {
        XCTAssertEqual(
            MenuBarViewModel.scanningDetail(for: .smartScan),
            "Looking for junk, large files, and threats…"
        )
        XCTAssertEqual(
            MenuBarViewModel.scanningDetail(for: .threatScan),
            "Checking this Mac for threats…"
        )
    }

    /// While a scan runs the recommendation card stays hidden — the
    /// Protection card is already narrating the activity.
    func test_recommendation_isNilWhileScanning() {
        XCTAssertNil(MenuBarViewModel.recommendation(
            protection: .scanning, disk: healthyDisk, pressure: .nominal, lastScanDate: nil, now: now
        ))
    }

    /// No scan date reads as "No scans yet"; a real date produces a non-empty
    /// relative phrase.
    func test_lastScanString_handlesNilAndDate() {
        XCTAssertEqual(MenuBarViewModel.lastScanString(nil), "No scans yet")
        let recent = MenuBarViewModel.lastScanString(Date(timeIntervalSinceNow: -3_600))
        XCTAssertFalse(recent.isEmpty)
        XCTAssertNotEqual(recent, "No scans yet")
    }

    // MARK: - Storage tile formatters

    /// The storage tile's headline rounds to whole GB — "670 GB", not
    /// "670.49 GB". Two decimals is false precision at menu-glance size.
    func test_availableDiskString_roundsToWholeGB() {
        // 1 TB total − 329.51 GB used = 670.49 GB free.
        let stats = DiskStats(usedBytes: 329_510_000_000, totalBytes: 1_000_000_000_000)
        let formatted = MenuBarViewModel.availableDiskString(stats)
        XCTAssertTrue(formatted.contains("670"), "Expected whole-GB value, got \(formatted)")
        XCTAssertFalse(formatted.contains("670.49") || formatted.contains("670,49"),
                       "Expected no fractional GB, got \(formatted)")
    }

    /// Below one GB the whole-GB rounding would render a useless "0 GB", so
    /// the formatter falls back to the shared byte formatter, which keeps the
    /// GB unit with a fraction ("0.5 GB") for layout stability.
    func test_availableDiskString_showsSubGBFraction() {
        let stats = DiskStats(usedBytes: 999_500_000_000, totalBytes: 1_000_000_000_000)
        let formatted = MenuBarViewModel.availableDiskString(stats)
        XCTAssertTrue(formatted.contains("0.5") || formatted.contains("0,5"),
                      "Expected fractional sub-GB value, got \(formatted)")
    }

    /// Used fraction drives the storage tile's capacity bar: used/total,
    /// clamped, and 0 for the zero-total pre-first-refresh state (not NaN).
    func test_diskUsedFraction_isUsedOverTotalClamped() {
        let stats = DiskStats(usedBytes: 600_000_000_000, totalBytes: 1_000_000_000_000)
        XCTAssertEqual(MenuBarViewModel.diskUsedFraction(stats), 0.6, accuracy: 0.001)
        XCTAssertEqual(MenuBarViewModel.diskUsedFraction(.empty), 0)
        let overfull = DiskStats(usedBytes: 2_000_000_000_000, totalBytes: 1_000_000_000_000)
        XCTAssertEqual(MenuBarViewModel.diskUsedFraction(overfull), 1.0)
    }

    // MARK: - Battery tile symbol + status

    private func makeCharge(percent: Int, isCharging: Bool = false, isPluggedIn: Bool = false) -> BatteryCharge {
        BatteryCharge(percent: percent, isCharging: isCharging, isPluggedIn: isPluggedIn,
                      timeRemainingMinutes: nil, temperatureCelsius: nil)
    }

    /// The battery tile's icon tracks the actual charge level instead of a
    /// hardcoded full battery.
    func test_batterySymbolName_bucketsChargeLevel() {
        XCTAssertEqual(MenuBarViewModel.batterySymbolName(makeCharge(percent: 5)), "battery.0percent")
        XCTAssertEqual(MenuBarViewModel.batterySymbolName(makeCharge(percent: 30)), "battery.25percent")
        XCTAssertEqual(MenuBarViewModel.batterySymbolName(makeCharge(percent: 50)), "battery.50percent")
        XCTAssertEqual(MenuBarViewModel.batterySymbolName(makeCharge(percent: 79)), "battery.75percent")
        XCTAssertEqual(MenuBarViewModel.batterySymbolName(makeCharge(percent: 95)), "battery.100percent")
    }

    /// Charging overlays the bolt regardless of level.
    func test_batterySymbolName_showsBoltWhileCharging() {
        XCTAssertEqual(
            MenuBarViewModel.batterySymbolName(makeCharge(percent: 40, isCharging: true, isPluggedIn: true)),
            "battery.100percent.bolt"
        )
    }

    /// No battery (desktop Macs) falls back to the generic full symbol the
    /// tile pairs with its "No battery" text.
    func test_batterySymbolName_fallsBackWithoutBattery() {
        XCTAssertEqual(MenuBarViewModel.batterySymbolName(nil), "battery.100percent")
    }

    /// The battery status dot mirrors the memory tile's traffic-light system:
    /// green while charging or comfortable, yellow when low, red when nearly
    /// empty, and absent without a battery.
    func test_batteryStatusColor_trafficLights() {
        XCTAssertEqual(MenuBarViewModel.batteryStatusColor(makeCharge(percent: 79)), .green)
        XCTAssertEqual(MenuBarViewModel.batteryStatusColor(makeCharge(percent: 15)), .yellow)
        XCTAssertEqual(MenuBarViewModel.batteryStatusColor(makeCharge(percent: 8)), .red)
        XCTAssertEqual(MenuBarViewModel.batteryStatusColor(makeCharge(percent: 8, isCharging: true, isPluggedIn: true)), .green)
        XCTAssertNil(MenuBarViewModel.batteryStatusColor(nil))
    }

    /// The CPU status dot buckets load: comfortable, busy, saturated.
    func test_cpuLoadColor_bucketsLoad() {
        XCTAssertEqual(MenuBarViewModel.cpuLoadColor(0.2), .green)
        XCTAssertEqual(MenuBarViewModel.cpuLoadColor(0.75), .yellow)
        XCTAssertEqual(MenuBarViewModel.cpuLoadColor(0.95), .red)
    }

    // MARK: - Recommendation

    private let healthyDisk = DiskStats(usedBytes: 400_000_000_000, totalBytes: 1_000_000_000_000)
    private let lowDisk = DiskStats(usedBytes: 950_000_000_000, totalBytes: 1_000_000_000_000)
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// Low disk is the cleaner app's most urgent recommendation — it outranks
    /// every other state, including an unscanned Mac (whose scan CTA lives on
    /// the Protection card).
    func test_recommendation_lowDiskOutranksEverything() {
        let rec = MenuBarViewModel.recommendation(
            protection: .notScanned, disk: lowDisk, pressure: .critical, lastScanDate: nil, now: now
        )
        XCTAssertEqual(rec?.target, .cleanup)
        XCTAssertEqual(rec?.startsScan, false)
        XCTAssertFalse(rec?.title.isEmpty ?? true)
        XCTAssertFalse(rec?.message.isEmpty ?? true)
        XCTAssertFalse(rec?.actionLabel.isEmpty ?? true)
    }

    /// Critical memory pressure recommends the Performance section when disk
    /// is comfortable.
    func test_recommendation_criticalMemoryWhenDiskComfortable() {
        let rec = MenuBarViewModel.recommendation(
            protection: .protected, disk: healthyDisk, pressure: .critical,
            lastScanDate: now.addingTimeInterval(-3_600), now: now
        )
        XCTAssertEqual(rec?.target, .performance)
    }

    /// When the Mac has never been scanned (or has live threats) the
    /// Protection card carries the scan CTA, so the recommendation card stays
    /// out of the way rather than duplicating the same button.
    func test_recommendation_isNilWhenProtectionCardOwnsTheCTA() {
        XCTAssertNil(MenuBarViewModel.recommendation(
            protection: .notScanned, disk: healthyDisk, pressure: .nominal, lastScanDate: nil, now: now
        ))
        XCTAssertNil(MenuBarViewModel.recommendation(
            protection: .threatsFound, disk: healthyDisk, pressure: .nominal,
            lastScanDate: now.addingTimeInterval(-3_600), now: now
        ))
    }

    /// A protected Mac whose last scan is over a week old is nudged toward a
    /// fresh Smart Scan.
    func test_recommendation_staleScanAfterSevenDays() {
        let rec = MenuBarViewModel.recommendation(
            protection: .protected, disk: healthyDisk, pressure: .nominal,
            lastScanDate: now.addingTimeInterval(-8 * 86_400), now: now
        )
        XCTAssertEqual(rec?.target, .smartScan)
        XCTAssertEqual(rec?.startsScan, true)
    }

    // MARK: - Displayed health verdict

    /// A never-scanned Mac caps the panel's verdict at Good: "Excellent" right
    /// above a "Not scanned — run your first scan" card contradicts itself.
    /// One scan restores the full verdict range.
    func test_displayedHealth_capsAtGoodUntilFirstScan() {
        XCTAssertEqual(MenuBarViewModel.displayedHealth(.excellent, hasScanned: false), .good)
        XCTAssertEqual(MenuBarViewModel.displayedHealth(.excellent, hasScanned: true), .excellent)
    }

    /// The cap only lowers the verdict — a real problem (Fair or worse) must
    /// never be *raised* toward Good by the scan rule.
    func test_displayedHealth_neverRaisesAWorseVerdict() {
        XCTAssertEqual(MenuBarViewModel.displayedHealth(.fair, hasScanned: false), .fair)
        XCTAssertEqual(MenuBarViewModel.displayedHealth(.critical, hasScanned: false), .critical)
        XCTAssertEqual(MenuBarViewModel.displayedHealth(.good, hasScanned: false), .good)
    }

    /// The measuring state (nil verdict) passes through untouched.
    func test_displayedHealth_preservesMeasuringState() {
        XCTAssertNil(MenuBarViewModel.displayedHealth(nil, hasScanned: false))
        XCTAssertNil(MenuBarViewModel.displayedHealth(nil, hasScanned: true))
    }

    // MARK: - Storage status dot

    /// The storage tile's dot mirrors the Health Monitor's disk-space tiers so
    /// the dot and the overall verdict never tell contradictory stories:
    /// comfortable is green, ≥90% used is yellow, ≥95% used is red.
    func test_diskStatusColor_bucketsUsage() {
        func stats(usedFraction: Double) -> DiskStats {
            DiskStats(usedBytes: UInt64(usedFraction * 1_000_000_000_000), totalBytes: 1_000_000_000_000)
        }
        XCTAssertEqual(MenuBarViewModel.diskStatusColor(stats(usedFraction: 0.50)), .green)
        XCTAssertEqual(MenuBarViewModel.diskStatusColor(stats(usedFraction: 0.85)), .green)
        XCTAssertEqual(MenuBarViewModel.diskStatusColor(stats(usedFraction: 0.92)), .yellow)
        XCTAssertEqual(MenuBarViewModel.diskStatusColor(stats(usedFraction: 0.96)), .red)
    }

    /// Pre-first-refresh (zero total) shows a neutral gray dot, not a false
    /// green — the disk hasn't been measured yet.
    func test_diskStatusColor_isGrayWhileUnmeasured() {
        XCTAssertEqual(MenuBarViewModel.diskStatusColor(.empty), .gray)
    }

    // MARK: - Status dot accessibility

    /// The 7pt status dots are color-only; VoiceOver needs words. Each color
    /// maps to a stable spoken description.
    func test_statusAccessibilityLabel_describesEveryColor() {
        XCTAssertEqual(MenuBarViewModel.statusAccessibilityLabel(for: .green), "OK")
        XCTAssertEqual(MenuBarViewModel.statusAccessibilityLabel(for: .yellow), "Needs attention")
        XCTAssertEqual(MenuBarViewModel.statusAccessibilityLabel(for: .red), "Critical")
        XCTAssertEqual(MenuBarViewModel.statusAccessibilityLabel(for: .gray), "Not available")
    }

    // MARK: - Connected devices overflow

    /// The devices tile shows at most three devices; beyond that it must say
    /// how many were hidden instead of truncating silently.
    func test_hiddenDevicesLabel_countsTheOverflow() {
        XCTAssertEqual(MenuBarViewModel.hiddenDevicesLabel(total: 5, shown: 3), "+2 more")
        XCTAssertEqual(MenuBarViewModel.hiddenDevicesLabel(total: 4, shown: 3), "+1 more")
    }

    /// No overflow, no label — three or fewer devices all fit.
    func test_hiddenDevicesLabel_isNilWhenEverythingFits() {
        XCTAssertNil(MenuBarViewModel.hiddenDevicesLabel(total: 3, shown: 3))
        XCTAssertNil(MenuBarViewModel.hiddenDevicesLabel(total: 0, shown: 0))
        XCTAssertNil(MenuBarViewModel.hiddenDevicesLabel(total: 2, shown: 2))
    }

    /// Everything healthy and recently scanned reads as all clear — an honest
    /// "nothing to do" instead of a manufactured plea, with Smart Scan still
    /// offered as the panel's habitual action.
    func test_recommendation_allClearWhenHealthyAndRecentlyScanned() {
        let stale = MenuBarViewModel.recommendation(
            protection: .protected, disk: healthyDisk, pressure: .nominal,
            lastScanDate: now.addingTimeInterval(-8 * 86_400), now: now
        )
        let rec = MenuBarViewModel.recommendation(
            protection: .protected, disk: healthyDisk, pressure: .nominal,
            lastScanDate: now.addingTimeInterval(-2 * 86_400), now: now
        )
        XCTAssertEqual(rec?.target, .smartScan)
        XCTAssertEqual(rec?.startsScan, true)
        XCTAssertNotEqual(rec?.title, stale?.title, "All-clear copy must differ from the stale-scan nudge")
    }

    // MARK: - Live scan narration

    /// While Smart Scan walks the disk the card narrates the live item tally —
    /// visible motion instead of a static sentence — falling back to the
    /// generic sentence before the first count arrives. The threat scan keeps
    /// its own copy; the tally parameter belongs to Smart Scan's file walks.
    func test_scanningDetail_narratesLiveItemTallyForSmartScan() {
        XCTAssertEqual(
            MenuBarViewModel.scanningDetail(for: .smartScan, itemsScanned: 12_405),
            "Checked \(12_405.formatted()) items so far…"
        )
        XCTAssertEqual(
            MenuBarViewModel.scanningDetail(for: .smartScan, itemsScanned: 0),
            "Looking for junk, large files, and threats…"
        )
        XCTAssertEqual(
            MenuBarViewModel.scanningDetail(for: .threatScan, itemsScanned: 500),
            "Checking this Mac for threats…"
        )
    }

    // MARK: - Inline memory flush

    /// The Memory tile's action really flushes RAM (via the injected helper
    /// call) and lands in `.flushed` so the tile can confirm the purge without
    /// deep-linking into the main window.
    func test_flushMemory_callsHelperAndLandsInFlushed() async {
        var flushed = false
        let vm = MenuBarViewModel(
            service: SystemStatsService(autostart: false),
            flushMemory: { flushed = true }
        )
        XCTAssertEqual(vm.memoryFlushState, .idle)

        await vm.flushMemory()

        XCTAssertTrue(flushed, "flushMemory() must invoke the injected helper call")
        XCTAssertEqual(vm.memoryFlushState, .flushed)
    }

    /// A dropped helper connection surfaces as `.failed` so the tile can offer
    /// a retry rather than pretending the purge happened.
    func test_flushMemory_failureLandsInFailed() async {
        struct Boom: Error {}
        let vm = MenuBarViewModel(
            service: SystemStatsService(autostart: false),
            flushMemory: { throw Boom() }
        )

        await vm.flushMemory()

        XCTAssertEqual(vm.memoryFlushState, .failed)
    }

    /// A second click while the purge is in flight must not start a second
    /// helper call — mirrors `runSpeedTest`'s in-flight guard.
    func test_flushMemory_ignoresReentrantCalls() async {
        var calls = 0
        // Holds the first flush observably mid-flight (the action can't
        // finish until the test releases it), so the re-entrant call below is
        // guaranteed to arrive while the state is `.running`.
        var release = false
        let vm = MenuBarViewModel(
            service: SystemStatsService(autostart: false),
            flushMemory: {
                calls += 1
                while !release { await Task.yield() }
            }
        )

        let first = Task { await vm.flushMemory() }
        while vm.memoryFlushState != .running { await Task.yield() }
        await vm.flushMemory()
        release = true
        await first.value

        XCTAssertEqual(calls, 1, "A flush in flight must swallow re-entrant calls")
        XCTAssertEqual(vm.memoryFlushState, .flushed)
    }

    /// Link copy for each flush state: an inviting verb at rest, a
    /// confirmation once purged, a retry after a failure, and `nil` while
    /// running (the tile shows a spinner instead of a label).
    func test_memoryFlushLabel_coversEveryState() {
        XCTAssertEqual(MenuBarViewModel.memoryFlushLabel(for: .idle), "Free Memory")
        XCTAssertNil(MenuBarViewModel.memoryFlushLabel(for: .running))
        XCTAssertEqual(MenuBarViewModel.memoryFlushLabel(for: .flushed), "Memory freed")
        XCTAssertEqual(MenuBarViewModel.memoryFlushLabel(for: .failed), "Retry")
    }
}
