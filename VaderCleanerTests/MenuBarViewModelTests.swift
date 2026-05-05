// MenuBarViewModelTests.swift
// Tests that MenuBarViewModel formats SystemStatsService values into menu-bar-ready strings and bridges service ticks to the popover.

import XCTest
import Combine
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
        XCTAssertEqual(MenuBarViewModel.formattedBatteryHealth(stats), "95%")
    }

    /// Desktops have no internal battery — the service publishes `nil` and the
    /// popover hides the row entirely. The formatter signals that with `nil`.
    func test_formattedBatteryHealth_isNilWhenNoBattery() {
        XCTAssertNil(MenuBarViewModel.formattedBatteryHealth(nil))
    }

    // MARK: - Pressure indicator

    func test_pressureLabel_returnsHumanReadable() {
        XCTAssertEqual(MenuBarViewModel.pressureLabel(for: .nominal), "Nominal")
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
            label.contains("RAM: 9999+ GB"),
            "Expected RAM segment to be capped, got \(label)"
        )
        XCTAssertTrue(
            label.contains("Disk: 9999+ GB free"),
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

    /// SwiftUI does not propagate a nested `ObservableObject`'s
    /// `objectWillChange` through an outer `ObservableObject` automatically.
    /// Without an explicit Combine bridge in `init`, the menu bar popover
    /// would freeze on its first frame. Same invariant
    /// `HealthMonitorViewModel` has — pinned here independently because the
    /// menu bar has its own subscription path.
    func test_serviceObjectWillChange_propagatesToViewModel() {
        let service = SystemStatsService(interval: 2.0, autostart: false)
        let sut = MenuBarViewModel(service: service)

        let expectation = XCTestExpectation(description: "VM re-publishes service tick")
        var cancellables = Set<AnyCancellable>()
        sut.objectWillChange
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        // Drive a refresh — the service's @Published setters fire
        // objectWillChange, which our bridge must forward to the VM so the
        // popover re-renders.
        service.refresh()

        wait(for: [expectation], timeout: 1.0)
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
        XCTAssertEqual(sut.formattedBatteryHealth, MenuBarViewModel.formattedBatteryHealth(service.batteryHealth))
        XCTAssertEqual(
            sut.menuBarLabelText,
            MenuBarViewModel.menuBarLabel(ram: service.ramUsage, disk: service.diskSpace)
        )
    }
}
