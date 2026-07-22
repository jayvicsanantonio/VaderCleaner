// MenuBarReadingTests.swift
// Tests the compact strings shown beside the menu bar icon for each reading choice.

import XCTest
@testable import VaderCleaner

@MainActor
final class MenuBarReadingTests: XCTestCase {

    private func makeViewModel() -> MenuBarViewModel {
        MenuBarViewModel(service: SystemStatsService(autostart: false))
    }

    func test_none_showsNothing() {
        XCTAssertNil(makeViewModel().compactReading(for: .none))
    }

    /// Every visible choice has to produce something — a `nil` here would
    /// render an icon with an empty gap beside it.
    func test_everyVisibleChoice_producesAString() {
        let viewModel = makeViewModel()

        for reading in MenuBarReading.allCases where reading != .none {
            let value = viewModel.compactReading(for: reading)
            XCTAssertNotNil(value, "\(reading) produced no string")
            XCTAssertFalse(value?.isEmpty ?? true, "\(reading) produced an empty string")
        }
    }

    // MARK: - Memory

    func test_memory_readsAsAUsedPercentage() {
        XCTAssertEqual(
            MenuBarViewModel.compactMemoryString(MemoryStats(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000)),
            "50%"
        )
    }

    /// Total bytes can be zero before the first refresh lands; dividing there
    /// would crash or render "nan%".
    func test_memory_survivesAZeroTotal() {
        XCTAssertEqual(
            MenuBarViewModel.compactMemoryString(MemoryStats(usedBytes: 0, totalBytes: 0)),
            "—"
        )
    }

    // MARK: - CPU

    func test_cpu_readsAsAWholePercentage() {
        XCTAssertEqual(MenuBarViewModel.compactCPUString(0.42), "42%")
        XCTAssertEqual(MenuBarViewModel.compactCPUString(0), "0%")
        XCTAssertEqual(MenuBarViewModel.compactCPUString(1), "100%")
    }

    /// A transient reading outside the unit interval must not reach the menu
    /// bar as "127%" or "-3%".
    func test_cpu_clampsOutOfRangeReadings() {
        XCTAssertEqual(MenuBarViewModel.compactCPUString(1.27), "100%")
        XCTAssertEqual(MenuBarViewModel.compactCPUString(-0.03), "0%")
    }

    /// Menu bar width is the scarcest space on screen — these strings sit
    /// beside the icon and must stay short enough to survive a crowded bar.
    func test_readings_stayNarrow() {
        let viewModel = makeViewModel()

        for reading in MenuBarReading.allCases {
            guard let value = viewModel.compactReading(for: reading) else { continue }
            XCTAssertLessThanOrEqual(value.count, 10, "\(reading) is too wide for the menu bar: \(value)")
        }
    }
}
