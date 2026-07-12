// HealthMonitorViewModelTests.swift
// Tests that HealthMonitorViewModel formats SystemStatsService values into display strings and status colors the Health Monitor cards bind to.

import XCTest
import Observation
@testable import VaderCleaner

@MainActor
final class HealthMonitorViewModelTests: XCTestCase {

    // MARK: - CPU formatting

    /// `cpuPercentString` is the value rendered in the CPU card. The
    /// service publishes a unit-interval `Double`; the card needs an integer
    /// percentage so a noisy reading doesn't visually thrash with decimals.
    func test_cpuPercentString_formatsZeroToOneDouble() {
        XCTAssertEqual(HealthMonitorViewModel.cpuPercentString(0.0), "0%")
        XCTAssertEqual(HealthMonitorViewModel.cpuPercentString(0.5), "50%")
        XCTAssertEqual(HealthMonitorViewModel.cpuPercentString(1.0), "100%")
    }

    /// Inputs outside `[0, 1]` must clamp rather than render `"-3%"` or
    /// `"137%"`. The service already clamps internally, but the formatter is
    /// the last line of defence — the menu bar (Prompt 10) and Smart Scan
    /// (Prompt 25) reuse it.
    func test_cpuPercentString_clampsOutOfRangeInputs() {
        XCTAssertEqual(HealthMonitorViewModel.cpuPercentString(-0.2), "0%")
        XCTAssertEqual(HealthMonitorViewModel.cpuPercentString(1.5), "100%")
    }

    /// Preserve the original `rounded()` tie behavior at x.5 percentage
    /// boundaries while still using localized percent formatting.
    func test_cpuPercentString_roundsHalfPercentBoundariesAwayFromZero() {
        XCTAssertEqual(HealthMonitorViewModel.cpuPercentString(0.005), "1%")
        XCTAssertEqual(HealthMonitorViewModel.cpuPercentString(0.025), "3%")
    }

    /// `cpuRatio` is what the card's progress bar binds to. Same clamp.
    func test_cpuRatio_clampsToUnitInterval() {
        XCTAssertEqual(HealthMonitorViewModel.cpuRatio(-0.5), 0.0)
        XCTAssertEqual(HealthMonitorViewModel.cpuRatio(0.5), 0.5)
        XCTAssertEqual(HealthMonitorViewModel.cpuRatio(1.5), 1.0)
    }

    // MARK: - RAM formatting

    /// `ramUsageString` formats `MemoryStats` to `"used / total"` in GB. We
    /// pin the GB unit explicitly (not "let the system pick") so 8 GB doesn't
    /// render as "8,000 MB" on a localised machine.
    func test_ramUsageString_formatsBytesToGB() {
        // 8 GB used / 16 GB total in decimal bytes (ByteCountFormatter default)
        let stats = MemoryStats(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000)
        let formatted = HealthMonitorViewModel.ramUsageString(stats)
        XCTAssertTrue(formatted.contains("8"), "Expected used GB in output, got \(formatted)")
        XCTAssertTrue(formatted.contains("16"), "Expected total GB in output, got \(formatted)")
        XCTAssertTrue(
            formatted.contains("/") || formatted.contains("of"),
            "Expected used/total separator, got \(formatted)"
        )
    }

    /// Zero-byte total is the pre-first-refresh state. The formatter must
    /// render something — not crash and not return empty — so the card can
    /// always show a value.
    func test_ramUsageString_handlesZeroTotal() {
        let stats = MemoryStats.empty
        let formatted = HealthMonitorViewModel.ramUsageString(stats)
        XCTAssertFalse(formatted.isEmpty)
    }

    /// The pressure-level badge color binds to `MemoryPressureLevel`. The
    /// thresholds are pinned in `SystemStatsServiceTests`; here we just pin
    /// the color mapping.
    func test_pressureColor_mapsLevelsToTrafficLights() {
        XCTAssertEqual(HealthMonitorViewModel.pressureColor(for: .nominal), .green)
        XCTAssertEqual(HealthMonitorViewModel.pressureColor(for: .fair), .yellow)
        XCTAssertEqual(HealthMonitorViewModel.pressureColor(for: .critical), .red)
    }

    func test_pressureLabel_isHumanReadable() {
        XCTAssertEqual(HealthMonitorViewModel.pressureLabel(for: .nominal), "Normal")
        XCTAssertEqual(HealthMonitorViewModel.pressureLabel(for: .fair), "Fair")
        XCTAssertEqual(HealthMonitorViewModel.pressureLabel(for: .critical), "Critical")
    }

    // MARK: - Disk space formatting

    /// `diskSpaceString` formats `DiskStats` to `"used / total"` in GB.
    func test_diskSpaceString_formatsBytesToGB() {
        // 256 GB used / 500 GB total
        let stats = DiskStats(usedBytes: 256_000_000_000, totalBytes: 500_000_000_000)
        let formatted = HealthMonitorViewModel.diskSpaceString(stats)
        XCTAssertTrue(formatted.contains("256"), "Expected used GB in output, got \(formatted)")
        XCTAssertTrue(formatted.contains("500"), "Expected total GB in output, got \(formatted)")
    }

    /// `diskUsageRatio` drives the % used bar. Same clamp behaviour as CPU.
    func test_diskUsageRatio_returnsUsedOverTotal() {
        let stats = DiskStats(usedBytes: 250, totalBytes: 1000)
        XCTAssertEqual(HealthMonitorViewModel.diskUsageRatio(stats), 0.25, accuracy: 0.0001)
    }

    /// Zero-total disk is implausible in practice but possible during the
    /// pre-first-refresh window — must not divide by zero.
    func test_diskUsageRatio_zeroTotalReturnsZero() {
        let stats = DiskStats.empty
        XCTAssertEqual(HealthMonitorViewModel.diskUsageRatio(stats), 0.0)
    }

    /// Disk space color escalates as the disk fills — green below 80%,
    /// yellow 80–95%, red above. Boundaries pinned here so a future refactor
    /// flipping `<` to `<=` is caught.
    func test_diskColor_escalatesWithUsage() {
        let comfortable = DiskStats(usedBytes: 500, totalBytes: 1000)
        XCTAssertEqual(HealthMonitorViewModel.diskColor(for: comfortable), .green)

        let getting = DiskStats(usedBytes: 850, totalBytes: 1000)
        XCTAssertEqual(HealthMonitorViewModel.diskColor(for: getting), .yellow)

        let dire = DiskStats(usedBytes: 970, totalBytes: 1000)
        XCTAssertEqual(HealthMonitorViewModel.diskColor(for: dire), .red)
    }

    /// Pin the inclusive/exclusive semantics at the bucket edges. A
    /// future refactor flipping `<` to `<=` (or vice versa) would silently
    /// shift the boundary cases — the interior cases above would still pass
    /// while the boundary readings flipped colors. These two assertions
    /// catch that.
    func test_diskColor_atExactThresholds() {
        // 0.80 exactly: still flips to yellow because comparison is `<`.
        let atWarning = DiskStats(usedBytes: 800, totalBytes: 1000)
        XCTAssertEqual(HealthMonitorViewModel.diskColor(for: atWarning), .yellow)

        // 0.95 exactly: still flips to red because comparison is `<`.
        let atCritical = DiskStats(usedBytes: 950, totalBytes: 1000)
        XCTAssertEqual(HealthMonitorViewModel.diskColor(for: atCritical), .red)
    }

    // MARK: - CPU color

    /// CPU color uses the same shape as disk color but with independently
    /// tunable thresholds. Pin both the bucket interiors and the exact
    /// boundaries.
    func test_cpuColor_escalatesWithUsage() {
        XCTAssertEqual(HealthMonitorViewModel.cpuColor(for: 0.20), .green)
        XCTAssertEqual(HealthMonitorViewModel.cpuColor(for: 0.85), .yellow)
        XCTAssertEqual(HealthMonitorViewModel.cpuColor(for: 0.97), .red)
        // Boundaries: same `<` semantics as disk.
        XCTAssertEqual(HealthMonitorViewModel.cpuColor(for: HealthMonitorViewModel.cpuWarningThreshold), .yellow)
        XCTAssertEqual(HealthMonitorViewModel.cpuColor(for: HealthMonitorViewModel.cpuCriticalThreshold), .red)
    }

    /// Out-of-range inputs clamp before the threshold check — a `1.5`
    /// reading from a buggy upstream must render red, not crash and not
    /// fall through to the default green branch.
    func test_cpuColor_clampsOutOfRangeInputs() {
        XCTAssertEqual(HealthMonitorViewModel.cpuColor(for: -0.3), .green)
        XCTAssertEqual(HealthMonitorViewModel.cpuColor(for: 1.5), .red)
    }

    // MARK: - Battery color + formatting

    /// `"Good"` and `"Normal"` are the two condition strings IOKit returns for
    /// a healthy battery (the key flipped from `BatteryHealth` to
    /// `BatteryHealthCondition` across macOS releases). Both must produce
    /// green so a perfectly healthy battery doesn't render yellow on older
    /// macOS.
    func test_batteryColor_isGreenForGoodCondition() {
        let good = BatteryStats(cycleCount: 100, maxCapacityPercent: 0.95, condition: "Good")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: .present(good)), .green)

        let normal = BatteryStats(cycleCount: 100, maxCapacityPercent: 0.95, condition: "Normal")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: .present(normal)), .green)
    }

    /// Apple's documented "needs service" condition strings — `"Service
    /// Battery"` (older macOS) and `"Service Recommended"` (newer) — are
    /// the two states that warrant a red dot on the card.
    func test_batteryColor_isRedForServiceCondition() {
        let service = BatteryStats(cycleCount: 1200, maxCapacityPercent: 0.65, condition: "Service Battery")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: .present(service)), .red)

        let serviceRecommended = BatteryStats(cycleCount: 1500, maxCapacityPercent: 0.60, condition: "Service Recommended")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: .present(serviceRecommended)), .red)
    }

    /// Anything else (`"Fair"`, `"Poor"`, `"Unknown"`) is yellow — it's not
    /// pristine but doesn't warrant the alarm of red.
    func test_batteryColor_isYellowForOtherKnownConditions() {
        let fair = BatteryStats(cycleCount: 800, maxCapacityPercent: 0.82, condition: "Fair")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: .present(fair)), .yellow)
    }

    /// Unknown startup state and true desktop/no-battery state are distinct,
    /// but both render as neutral health colors.
    func test_batteryColor_isGrayWhenUnknownOrAbsent() {
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: .unknown), .gray)
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: .absent), .gray)
    }

    /// `batteryCapacityString` formats the unit-interval capacity as a
    /// percentage. `0.95` → `"95%"`.
    func test_batteryCapacityString_formatsAsPercent() {
        let stats = BatteryStats(cycleCount: 100, maxCapacityPercent: 0.95, condition: "Good")
        XCTAssertEqual(HealthMonitorViewModel.batteryCapacityString(stats), "95%")
    }

    func test_batteryCapacityString_roundsHalfPercentBoundariesAwayFromZero() {
        let stats = BatteryStats(cycleCount: 100, maxCapacityPercent: 0.005, condition: "Good")
        XCTAssertEqual(HealthMonitorViewModel.batteryCapacityString(stats), "1%")
    }

    /// `batteryCapacityRatio` exposes the present battery's capacity as a
    /// unit-interval value for the card's fill ring. A present battery reports
    /// its `maxCapacityPercent`; an absent or unknown battery reports `0` so the
    /// ring renders empty rather than full.
    func test_batteryCapacityRatio_returnsCapacityWhenPresent() {
        let stats = BatteryStats(cycleCount: 237, maxCapacityPercent: 0.88, condition: "Normal")
        XCTAssertEqual(HealthMonitorViewModel.batteryCapacityRatio(for: .present(stats)), 0.88, accuracy: 0.0001)
    }

    func test_batteryCapacityRatio_isZeroWhenAbsentOrUnknown() {
        XCTAssertEqual(HealthMonitorViewModel.batteryCapacityRatio(for: .unknown), 0.0)
        XCTAssertEqual(HealthMonitorViewModel.batteryCapacityRatio(for: .absent), 0.0)
    }

    /// Out-of-range capacity clamps to `[0, 1]` so the ring's trim never
    /// overshoots the circle.
    func test_batteryCapacityRatio_clampsToUnitInterval() {
        let over = BatteryStats(cycleCount: 0, maxCapacityPercent: 1.4, condition: "Good")
        XCTAssertEqual(HealthMonitorViewModel.batteryCapacityRatio(for: .present(over)), 1.0)

        let under = BatteryStats(cycleCount: 0, maxCapacityPercent: -0.2, condition: "Good")
        XCTAssertEqual(HealthMonitorViewModel.batteryCapacityRatio(for: .present(under)), 0.0)
    }

    /// `ramUsageRatio` exposes `usedBytes / totalBytes` as a unit-interval value
    /// for the Memory card's fill ring, and returns `0` for the zero-total
    /// pre-first-refresh state rather than dividing by zero.
    func test_ramUsageRatio_returnsUsedOverTotal() {
        let stats = MemoryStats(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000)
        XCTAssertEqual(HealthMonitorViewModel.ramUsageRatio(stats), 0.5, accuracy: 0.0001)
    }

    func test_ramUsageRatio_zeroTotalReturnsZero() {
        XCTAssertEqual(HealthMonitorViewModel.ramUsageRatio(.empty), 0.0)
    }

    // MARK: - System snapshot (hero details)

    /// Uptime renders as the two largest non-zero units so the hero row stays
    /// compact: days+hours, else hours+minutes, else minutes.
    func test_uptimeString_showsTwoLargestUnits() {
        XCTAssertEqual(HealthMonitorViewModel.uptimeString(0), "0m")
        XCTAssertEqual(HealthMonitorViewModel.uptimeString(90), "1m")            // 1m 30s
        XCTAssertEqual(HealthMonitorViewModel.uptimeString(3600), "1h 0m")
        XCTAssertEqual(HealthMonitorViewModel.uptimeString(3661), "1h 1m")
        XCTAssertEqual(HealthMonitorViewModel.uptimeString(86400), "1d 0h")
        XCTAssertEqual(HealthMonitorViewModel.uptimeString(90000), "1d 1h")      // 25h
        XCTAssertEqual(HealthMonitorViewModel.uptimeString(4 * 86400 + 3 * 3600), "4d 3h")
    }

    /// Negative or garbage uptime clamps to zero rather than rendering a
    /// negative duration.
    func test_uptimeString_clampsNegative() {
        XCTAssertEqual(HealthMonitorViewModel.uptimeString(-500), "0m")
    }

    /// The OS string is the major.minor of the running system, prefixed "macOS".
    func test_osVersionString_formatsMajorMinor() {
        let v = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        XCTAssertEqual(HealthMonitorViewModel.osVersionString(v), "macOS 26.1")

        let patched = OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 2)
        XCTAssertEqual(HealthMonitorViewModel.osVersionString(patched), "macOS 15.3")
    }

    // MARK: - Mac Health score (hero gauge fill)

    /// The hero ring fills to a fraction that rises with the verdict, so the arc
    /// itself communicates how healthy the Mac is. Best tier fills the ring;
    /// each worse tier fills less, and the worst still shows a sliver.
    func test_macHealthScore_risesWithVerdict() {
        XCTAssertEqual(MacHealthStatus.excellent.score, 1.0, accuracy: 0.0001)
        // Strictly decreasing across the tiers, ordered best-to-worst.
        let ordered: [MacHealthStatus] = [.excellent, .good, .fair, .requiresAttention, .critical]
        for (better, worse) in zip(ordered, ordered.dropFirst()) {
            XCTAssertGreaterThan(better.score, worse.score)
        }
        // Even the worst verdict leaves a visible arc rather than an empty ring.
        XCTAssertGreaterThan(MacHealthStatus.critical.score, 0.0)
    }

    // MARK: - SMART color

    /// `.failing` is the only state that warrants a red dot — the user should
    /// be backing up immediately.
    func test_smartColor_isRedForFailing() {
        XCTAssertEqual(HealthMonitorViewModel.smartColor(for: .failing), .red)
    }

    /// `.good` (diskutil's `"Verified"`) is the green case. `.unknown` is
    /// gray — common on Apple Silicon where `diskutil` reports "Verified" but
    /// some external NVMe enclosures decline to.
    func test_smartColor_isGreenForGoodAndGrayForUnknown() {
        XCTAssertEqual(HealthMonitorViewModel.smartColor(for: .good), .green)
        XCTAssertEqual(HealthMonitorViewModel.smartColor(for: .unknown), .gray)
    }

    /// Human-readable label rendered on the SMART card.
    func test_smartLabel_isHumanReadable() {
        XCTAssertEqual(HealthMonitorViewModel.smartLabel(for: .good), "Good")
        XCTAssertEqual(HealthMonitorViewModel.smartLabel(for: .failing), "Failing")
        XCTAssertEqual(HealthMonitorViewModel.smartLabel(for: .unknown), "Unknown")
    }

    // MARK: - FileVault footer

    func test_fileVaultLabel_reflectsTriState() {
        XCTAssertEqual(HealthMonitorViewModel.fileVaultLabel(for: .unknown), "FileVault: —")
        XCTAssertEqual(HealthMonitorViewModel.fileVaultLabel(for: .on), "FileVault: On")
        XCTAssertEqual(HealthMonitorViewModel.fileVaultLabel(for: .off), "FileVault: Off")
    }

    func test_fileVaultIconName_reflectsTriState() {
        XCTAssertEqual(HealthMonitorViewModel.fileVaultIconName(for: .unknown), "questionmark.circle")
        XCTAssertEqual(HealthMonitorViewModel.fileVaultIconName(for: .on), "lock.shield.fill")
        XCTAssertEqual(HealthMonitorViewModel.fileVaultIconName(for: .off), "lock.open")
    }

    func test_fileVaultColor_reflectsTriState() {
        XCTAssertEqual(HealthMonitorViewModel.fileVaultColor(for: .unknown), .gray)
        XCTAssertEqual(HealthMonitorViewModel.fileVaultColor(for: .on), .green)
        XCTAssertEqual(HealthMonitorViewModel.fileVaultColor(for: .off), .yellow)
    }

    // MARK: - Service binding

    /// The view-model wraps a `SystemStatsService`. Constructing the VM with
    /// a real (non-autostarted) service must not crash — exercises the init
    /// path used in production via `@StateObject`.
    func test_initWithService_storesServiceReference() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        let sut = HealthMonitorViewModel(service: service)
        XCTAssertTrue(sut.service === service)
    }

    /// Critical end-to-end invariant: when the underlying service mutates a
    /// tracked property, any view (or test) observing the VM's derived
    /// reading must be invalidated. Under the Observation framework SwiftUI
    /// tracks the read chain `view → vm.ramUsage → service.ramUsage`
    /// transparently, so the Health Monitor re-renders on each tick
    /// without a manual `objectWillChange` bridge.
    ///
    /// `ramUsage` rather than `cpuUsage` because the first `refresh()` seeds
    /// `previousCPUTotals` and re-publishes the existing `cpuUsage` value —
    /// the setter still fires under Observation, but pinning the assertion
    /// to a property that actually changes is more robust against future
    /// Observation-optimisation changes.
    func test_servicePropertyChange_invalidatesViewModelDerivedReads() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        let sut = HealthMonitorViewModel(service: service)

        var fired = false
        withObservationTracking {
            _ = sut.ramUsage
        } onChange: {
            fired = true
        }

        // Drive a refresh — the service's tracked-property setters fire
        // Observation registrations on every view (or test) reading the
        // chain, so the Health Monitor card re-renders without any extra
        // wiring.
        service.refresh()

        XCTAssertTrue(
            fired,
            "Mutating service.ramUsage must invalidate views observing vm.ramUsage"
        )
    }

    // MARK: - Mac Health verdict (hero card)

    /// Builds a `DiskStats` at a target fullness ratio against a fixed total
    /// so the derivation thresholds read clearly in each test.
    private func disk(ratio: Double) -> DiskStats {
        let total: UInt64 = 1_000_000_000_000
        return DiskStats(usedBytes: UInt64(Double(total) * ratio), totalBytes: total)
    }

    /// A healthy present battery — the common case that must never penalize.
    private let goodBattery = BatteryAvailability.present(
        BatteryStats(cycleCount: 100, maxCapacityPercent: 0.95, condition: "Normal")
    )

    /// The very first service tick carries `DiskStats.empty` (zero total).
    /// The hero must NOT resolve to a confident verdict off zero data — it
    /// returns `nil` so the view can render a neutral "Measuring…" state.
    func test_macHealthStatus_isNilWhileDiskUnmeasured() {
        XCTAssertNil(
            HealthMonitorViewModel.macHealthStatus(disk: .empty, smart: .unknown, battery: .unknown)
        )
    }

    /// CleanMyMac-style optimism: with no problem on any tracked factor the
    /// verdict is Excellent — including the common real-world case of a
    /// partly-full disk and an unreadable battery condition (the exact inputs
    /// that previously dragged the verdict down to "Fair").
    func test_macHealthStatus_isExcellentWhenNoProblems() {
        XCTAssertEqual(
            HealthMonitorViewModel.macHealthStatus(disk: disk(ratio: 0.64), smart: .good, battery: goodBattery),
            .excellent
        )
        let unknownBattery = BatteryAvailability.present(
            BatteryStats(cycleCount: 222, maxCapacityPercent: 0.89, condition: "Unknown")
        )
        XCTAssertEqual(
            HealthMonitorViewModel.macHealthStatus(disk: disk(ratio: 0.64), smart: .unknown, battery: unknownBattery),
            .excellent
        )
    }

    /// Absent / unknown battery and unknown SMART are "no opinion", never a
    /// problem.
    func test_macHealthStatus_neutralSignalsDoNotPenalize() {
        XCTAssertEqual(
            HealthMonitorViewModel.macHealthStatus(disk: disk(ratio: 0.30), smart: .unknown, battery: .absent),
            .excellent
        )
    }

    /// A failing drive is the most serious problem and forces Critical even on
    /// a near-empty disk with a healthy battery.
    func test_macHealthStatus_failingSmartIsCritical() {
        XCTAssertEqual(
            HealthMonitorViewModel.macHealthStatus(disk: disk(ratio: 0.10), smart: .failing, battery: goodBattery),
            .critical
        )
    }

    /// A battery reporting a service condition demotes the verdict to Requires
    /// Attention — CleanMyMac's "critical battery health" factor. Capacity fade
    /// alone (a low percentage with a non-service condition) must not.
    func test_macHealthStatus_serviceBatteryRequiresAttention() {
        let service = BatteryAvailability.present(
            BatteryStats(cycleCount: 1500, maxCapacityPercent: 0.60, condition: "Service Recommended")
        )
        XCTAssertEqual(
            HealthMonitorViewModel.macHealthStatus(disk: disk(ratio: 0.30), smart: .good, battery: service),
            .requiresAttention
        )
    }

    /// The verdict is the worst tier any factor produces — no compounding, no
    /// double-counting.
    func test_macHealthStatus_worstFactorWins() {
        // Near-full disk (Fair) under a failing drive (Critical) → Critical.
        XCTAssertEqual(
            HealthMonitorViewModel.macHealthStatus(disk: disk(ratio: 0.92), smart: .failing, battery: goodBattery),
            .critical
        )
        // Disk getting full (Good) plus a service battery (Requires Attention)
        // → the battery problem dominates.
        let service = BatteryAvailability.present(
            BatteryStats(cycleCount: 1500, maxCapacityPercent: 0.60, condition: "Service Battery")
        )
        XCTAssertEqual(
            HealthMonitorViewModel.macHealthStatus(disk: disk(ratio: 0.82), smart: .good, battery: service),
            .requiresAttention
        )
    }

    /// Low-disk-space ramp. Only a genuinely full disk is a problem; a
    /// half-full disk is Excellent. Pins each bucket interior so the ramp can't
    /// silently shift.
    func test_diskSpaceTier_escalatesNearFull() {
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.64)), .excellent)
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.85)), .good)
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.92)), .fair)
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.96)), .requiresAttention)
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.99)), .critical)
    }

    /// Pin the inclusive-lower-bound semantics at each disk tier edge so a
    /// future `<`/`<=` flip is caught.
    func test_diskSpaceTier_atExactThresholds() {
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.80)), .good)
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.90)), .fair)
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.95)), .requiresAttention)
        XCTAssertEqual(HealthMonitorViewModel.diskSpaceTier(for: disk(ratio: 0.98)), .critical)
    }

    /// The hero title and summary are user-facing strings; pin one tier so a
    /// typo or accidental copy change is caught.
    func test_macHealthStatus_titleAndSummaryCopy() {
        XCTAssertEqual(MacHealthStatus.good.title, "Good")
        XCTAssertTrue(MacHealthStatus.good.summary.contains("good shape"))
        XCTAssertEqual(MacHealthStatus.excellent.title, "Excellent")
    }

    // MARK: - Displayed health verdict

    /// A never-scanned Mac caps the rendered verdict at Good — "Excellent"
    /// alongside a "run your first scan" prompt contradicts itself. This rule
    /// is shared with the menu bar panel (which forwards to it) so the hero
    /// and the menu can never disagree about the same Mac.
    func test_displayedHealth_capsAtGoodUntilFirstScan() {
        XCTAssertEqual(HealthMonitorViewModel.displayedHealth(.excellent, hasScanned: false), .good)
        XCTAssertEqual(HealthMonitorViewModel.displayedHealth(.excellent, hasScanned: true), .excellent)
    }

    /// The cap only lowers the verdict — a real problem (Fair or worse) must
    /// never be *raised* toward Good by the scan rule.
    func test_displayedHealth_neverRaisesAWorseVerdict() {
        XCTAssertEqual(HealthMonitorViewModel.displayedHealth(.fair, hasScanned: false), .fair)
        XCTAssertEqual(HealthMonitorViewModel.displayedHealth(.critical, hasScanned: false), .critical)
        XCTAssertEqual(HealthMonitorViewModel.displayedHealth(.good, hasScanned: false), .good)
    }

    /// The measuring state (nil verdict) passes through untouched.
    func test_displayedHealth_preservesMeasuringState() {
        XCTAssertNil(HealthMonitorViewModel.displayedHealth(nil, hasScanned: false))
        XCTAssertNil(HealthMonitorViewModel.displayedHealth(nil, hasScanned: true))
    }

    /// The menu bar panel's forwarding stays in lockstep with the hero's rule
    /// — one implementation, two surfaces.
    func test_displayedHealth_menuBarForwardsToTheSameRule() {
        for hasScanned in [true, false] {
            for status in MacHealthStatus.allCases {
                XCTAssertEqual(
                    MenuBarViewModel.displayedHealth(status, hasScanned: hasScanned),
                    HealthMonitorViewModel.displayedHealth(status, hasScanned: hasScanned)
                )
            }
        }
    }
}
