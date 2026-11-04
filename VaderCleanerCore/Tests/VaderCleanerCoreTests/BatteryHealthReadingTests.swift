// BatteryHealthReadingTests.swift
// Tests how battery health is read: Apple's own report from system_profiler, the IOKit registry fallback in both its old and nested layouts, and — on a Mac with a battery — that the two agree with the installed macOS.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite struct BatteryHealthReadingTests {

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - system_profiler report

    @Test func reportReadsAppleConditionAndCapacity() throws {
        let data = try Self.json(["SPPowerDataType": [
            ["_name": "spbattery_information", "sppower_battery_health_info": [
                "sppower_battery_cycle_count": 272,
                "sppower_battery_health": "Good",
                "sppower_battery_health_maximum_capacity": "89%",
            ]],
            ["_name": "sppower_information"],
        ]])
        let report = SystemStatsService.batteryHealthReport(fromSystemProfilerJSON: data)
        #expect(report == BatteryHealthReport(condition: "Good", maxCapacityPercent: 0.89))
    }

    @Test func reportPassesAServiceConditionThrough() throws {
        let data = try Self.json(["SPPowerDataType": [
            ["sppower_battery_health_info": ["sppower_battery_health": "Service Recommended"]],
        ]])
        let report = SystemStatsService.batteryHealthReport(fromSystemProfilerJSON: data)
        #expect(report == BatteryHealthReport(condition: "Service Recommended", maxCapacityPercent: nil))
    }

    @Test func reportIsAbsentOnAMacWithNoBattery() throws {
        let data = try Self.json(["SPPowerDataType": [["_name": "sppower_information"]]])
        #expect(SystemStatsService.batteryHealthReport(fromSystemProfilerJSON: data) == nil)
    }

    @Test func reportIsAbsentForUnreadableOutput() {
        #expect(SystemStatsService.batteryHealthReport(fromSystemProfilerJSON: Data("not json".utf8)) == nil)
    }

    // MARK: - Registry fallback

    /// The macOS 27 layout: capacities moved into `BatteryData`, the condition
    /// key is gone, and the top-level `MaxCapacity` is a percentage (100), not
    /// a capacity — reading it as one made every battery "0%".
    @Test func registryReadsTheNestedBatteryData() {
        let registry: [String: Any] = [
            "CycleCount": 272,
            "MaxCapacity": 100,
            "BatteryData": ["DesignCapacity": 8579, "NominalChargeCapacity": 7540, "AppleRawMaxCapacity": 7296, "MaxCapacity": 100],
        ]
        let stats = SystemStatsService.batteryStats(registry: registry, report: nil)
        #expect(stats.cycleCount == 272)
        #expect(abs(stats.maxCapacityPercent - 7540.0 / 8579.0) < 0.0001)
        #expect(stats.condition == "Unknown")
    }

    @Test func registryStillReadsTheOlderTopLevelLayout() {
        let registry: [String: Any] = [
            "CycleCount": 100,
            "AppleRawMaxCapacity": 4000,
            "DesignCapacity": 5000,
            "BatteryHealthCondition": "Normal",
        ]
        let stats = SystemStatsService.batteryStats(registry: registry, report: nil)
        #expect(stats.maxCapacityPercent == 0.8)
        #expect(stats.condition == "Normal")
    }

    @Test func aPercentageMaxCapacityIsNeverReadAsACapacity() {
        let registry: [String: Any] = ["CycleCount": 5, "MaxCapacity": 100]
        let stats = SystemStatsService.batteryStats(registry: registry, report: nil)
        #expect(stats.maxCapacityPercent == 0, "no design capacity means no readable capacity")
    }

    @Test func appleReportWinsOverTheRegistry() {
        let registry: [String: Any] = [
            "CycleCount": 272,
            "BatteryData": ["DesignCapacity": 8579, "NominalChargeCapacity": 7540],
        ]
        let report = BatteryHealthReport(condition: "Good", maxCapacityPercent: 0.89)
        let stats = SystemStatsService.batteryStats(registry: registry, report: report)
        #expect(stats == BatteryStats(cycleCount: 272, maxCapacityPercent: 0.89, condition: "Good"))
    }

    @Test func reportWithoutACapacityKeepsTheRegistryFigure() {
        let registry: [String: Any] = ["CycleCount": 10, "BatteryData": ["DesignCapacity": 1000, "NominalChargeCapacity": 900]]
        let report = BatteryHealthReport(condition: "Service Recommended", maxCapacityPercent: nil)
        let stats = SystemStatsService.batteryStats(registry: registry, report: report)
        #expect(stats.maxCapacityPercent == 0.9)
        #expect(stats.condition == "Service Recommended")
    }

    // MARK: - The installed macOS

    /// Both readings are facts about the installed OS that fail silently when
    /// macOS moves a key, so check them against this Mac. A desktop has no
    /// battery and nothing to check.
    @Test func bothReadingsWorkOnThisMac() throws {
        guard let registry = SystemStatsService.readBatteryRegistry() else { return }
        let report = try #require(SystemStatsService.readBatteryHealthReport(), "system_profiler must report a battery this Mac has")
        #expect(!report.condition.isEmpty)
        let appleFigure = try #require(report.maxCapacityPercent)
        let registryFigure = SystemStatsService.batteryStats(registry: registry, report: nil).maxCapacityPercent
        #expect(registryFigure > 0, "the registry fallback must still find the capacities")
        #expect(abs(registryFigure - appleFigure) < 0.05, "the fallback should land within a few points of Apple's figure")
    }
}
