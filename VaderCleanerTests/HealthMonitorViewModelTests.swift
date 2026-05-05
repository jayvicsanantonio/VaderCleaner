// HealthMonitorViewModelTests.swift
// Tests that HealthMonitorViewModel formats SystemStatsService values into display strings and status colors the Health Monitor cards bind to.

import XCTest
import Combine
@testable import VaderCleaner

@MainActor
final class HealthMonitorViewModelTests: XCTestCase {

    // MARK: - CPU formatting

    /// `cpuPercentString` is the value rendered in the CPU Load card. The
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
        XCTAssertEqual(HealthMonitorViewModel.pressureLabel(for: .nominal), "Nominal")
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
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: good), .green)

        let normal = BatteryStats(cycleCount: 100, maxCapacityPercent: 0.95, condition: "Normal")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: normal), .green)
    }

    /// Apple's documented "needs service" condition strings — `"Service
    /// Battery"` (older macOS) and `"Service Recommended"` (newer) — are
    /// the two states that warrant a red dot on the card.
    func test_batteryColor_isRedForServiceCondition() {
        let service = BatteryStats(cycleCount: 1200, maxCapacityPercent: 0.65, condition: "Service Battery")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: service), .red)

        let serviceRecommended = BatteryStats(cycleCount: 1500, maxCapacityPercent: 0.60, condition: "Service Recommended")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: serviceRecommended), .red)
    }

    /// Anything else (`"Fair"`, `"Poor"`, `"Unknown"`) is yellow — it's not
    /// pristine but doesn't warrant the alarm of red.
    func test_batteryColor_isYellowForOtherKnownConditions() {
        let fair = BatteryStats(cycleCount: 800, maxCapacityPercent: 0.82, condition: "Fair")
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: fair), .yellow)
    }

    /// Desktops have no internal battery — the service publishes `nil`. The
    /// card displays a neutral "—" + gray dot instead of being absent.
    func test_batteryColor_isGrayWhenNoBattery() {
        XCTAssertEqual(HealthMonitorViewModel.batteryColor(for: nil), .gray)
    }

    /// `batteryCapacityString` formats the unit-interval capacity as a
    /// percentage. `0.95` → `"95%"`.
    func test_batteryCapacityString_formatsAsPercent() {
        let stats = BatteryStats(cycleCount: 100, maxCapacityPercent: 0.95, condition: "Good")
        XCTAssertEqual(HealthMonitorViewModel.batteryCapacityString(stats), "95%")
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

    func test_fileVaultLabel_reflectsEnabledState() {
        XCTAssertEqual(HealthMonitorViewModel.fileVaultLabel(enabled: true), "FileVault: On")
        XCTAssertEqual(HealthMonitorViewModel.fileVaultLabel(enabled: false), "FileVault: Off")
    }

    func test_fileVaultColor_isGreenWhenEnabled() {
        XCTAssertEqual(HealthMonitorViewModel.fileVaultColor(enabled: true), .green)
        XCTAssertEqual(HealthMonitorViewModel.fileVaultColor(enabled: false), .yellow)
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

    /// Critical end-to-end invariant: when the underlying service publishes
    /// a tick, the view-model must re-publish so views bound via
    /// `@StateObject` re-evaluate their computed properties. SwiftUI does
    /// not propagate a nested `ObservableObject`'s changes through an outer
    /// `ObservableObject` automatically — without an explicit Combine
    /// bridge in `init`, the Health Monitor would freeze on its first
    /// frame. This test pins the bridge.
    func test_serviceObjectWillChange_propagatesToViewModel() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        let sut = HealthMonitorViewModel(service: service)

        let expectation = XCTestExpectation(description: "VM re-publishes service tick")
        var cancellables = Set<AnyCancellable>()
        sut.objectWillChange
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        // Drive a refresh — the service's @Published setters fire
        // objectWillChange, which our bridge must forward to the VM.
        service.refresh()

        wait(for: [expectation], timeout: 1.0)
    }
}
