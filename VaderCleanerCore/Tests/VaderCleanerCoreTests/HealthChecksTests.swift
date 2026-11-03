// HealthChecksTests.swift
// Tests the Health Monitor's checks and verdict: each check's status and plain-language detail, the summary that names what to watch, and the live-load labels.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite struct HealthChecksTests {

    private static let gb: UInt64 = 1_000_000_000
    private static let roomyDisk = DiskStats(usedBytes: 500 * gb, totalBytes: 1_000 * gb)
    private static let fullishDisk = DiskStats(usedBytes: 810 * gb, totalBytes: 1_000 * gb)
    private static let fullDisk = DiskStats(usedBytes: 960 * gb, totalBytes: 1_000 * gb)
    private static let goodBattery = BatteryAvailability.present(BatteryStats(cycleCount: 272, maxCapacityPercent: 0.89, condition: "Good"))

    private static func checks(
        disk: DiskStats = roomyDisk,
        battery: BatteryAvailability = goodBattery,
        smart: SMARTStatus = .good,
        fileVault: FileVaultState = .on
    ) -> [HealthCheck] {
        HealthChecks.checks(disk: disk, battery: battery, smart: smart, fileVault: fileVault)
    }

    private static func check(_ kind: HealthCheck.Kind, in checks: [HealthCheck]) throws -> HealthCheck {
        try #require(checks.first { $0.kind == kind })
    }

    // MARK: - Storage

    @Test(arguments: [
        (roomyDisk, HealthCheck.Status.good),
        (fullishDisk, .watch),
        (fullDisk, .act),
    ])
    func storageStatusFollowsHowFullTheDiskIs(disk: DiskStats, status: HealthCheck.Status) throws {
        #expect(try Self.check(.storage, in: Self.checks(disk: disk)).status == status)
    }

    @Test func storageDetailSaysHowMuchIsFree() throws {
        let storage = try Self.check(.storage, in: Self.checks(disk: Self.fullishDisk))
        #expect(storage.detail == "\(SystemStatsFormatters.byteString(190 * Self.gb)) free of \(SystemStatsFormatters.byteString(1_000 * Self.gb))")
        #expect(storage.ratio == 0.81)
    }

    // MARK: - Battery

    @Test func batteryDetailPairsCapacityWithCycles() throws {
        let battery = try Self.check(.battery, in: Self.checks())
        #expect(battery.status == .good)
        #expect(battery.detail == "89% of original capacity · 272 cycles")
    }

    @Test func batteryWithoutAReadableCapacityShowsCyclesOnly() throws {
        let unreadable = BatteryAvailability.present(BatteryStats(cycleCount: 40, maxCapacityPercent: 0, condition: "Good"))
        #expect(try Self.check(.battery, in: Self.checks(battery: unreadable)).detail == "40 cycles")
    }

    @Test(arguments: [
        ("Normal", HealthCheck.Status.good),
        ("Service Recommended", .act),
        ("Fair", .watch),
        ("Unknown", .unknown),
    ])
    func batteryStatusFollowsTheCondition(condition: String, status: HealthCheck.Status) throws {
        let battery = BatteryAvailability.present(BatteryStats(cycleCount: 1, maxCapacityPercent: 0.9, condition: condition))
        #expect(try Self.check(.battery, in: Self.checks(battery: battery)).status == status)
    }

    @Test func aMacWithNoBatteryHasNoBatteryCheck() {
        #expect(!Self.checks(battery: .absent).contains { $0.kind == .battery })
    }

    @Test func anUnreadBatteryIsStillBeingChecked() throws {
        let battery = try Self.check(.battery, in: Self.checks(battery: .unknown))
        #expect(battery.status == .unknown)
        #expect(battery.detail == "Checking…")
    }

    // MARK: - Drive and encryption

    @Test(arguments: [
        (SMARTStatus.good, HealthCheck.Status.good, "No problems reported by the drive"),
        (.failing, .act, "The drive reports it may fail — back up now"),
        (.unknown, .unknown, "This drive doesn't report its condition"),
    ])
    func driveCheckSpeaksPlainly(smart: SMARTStatus, status: HealthCheck.Status, detail: String) throws {
        let drive = try Self.check(.drive, in: Self.checks(smart: smart))
        #expect(drive.status == status)
        #expect(drive.detail == detail)
    }

    @Test(arguments: [
        (FileVaultState.on, HealthCheck.Status.good, "FileVault is on"),
        (.off, .watch, "FileVault is off, so your files aren't encrypted"),
        (.unknown, .unknown, "Checking…"),
    ])
    func encryptionCheckSpeaksPlainly(fileVault: FileVaultState, status: HealthCheck.Status, detail: String) throws {
        let encryption = try Self.check(.encryption, in: Self.checks(fileVault: fileVault))
        #expect(encryption.status == status)
        #expect(encryption.detail == detail)
    }

    @Test func checksKeepAFixedOrder() {
        #expect(Self.checks().map(\.kind) == [.storage, .battery, .drive, .encryption])
    }

    @Test(arguments: [
        (HealthCheck.Status.good, "Good"),
        (.watch, "Watch"),
        (.act, "Act now"),
        (.unknown, "Unknown"),
    ])
    func everyStatusHasAWord(status: HealthCheck.Status, word: String) {
        #expect(status.label == word)
    }

    // MARK: - Summary

    @Test func healthyMacSaysSo() {
        let summary = HealthChecks.summary(verdict: .excellent, checks: Self.checks())
        #expect(summary == HealthSummary(headline: "Your Mac is healthy", reason: "Everything we check looks good.", action: nil))
    }

    @Test func oneConcernIsNamedWithItsAction() {
        let summary = HealthChecks.summary(verdict: .good, checks: Self.checks(disk: Self.fullishDisk))
        #expect(summary.headline == "Your Mac is healthy")
        #expect(summary.reason == "One thing to watch: your disk is 81% full.")
        #expect(summary.action == .freeUpSpace)
    }

    @Test func severalConcernsAreListed() {
        let summary = HealthChecks.summary(verdict: .critical, checks: Self.checks(disk: Self.fullDisk, smart: .failing))
        #expect(summary.headline == "Your Mac needs attention now")
        #expect(summary.reason == "2 things to watch: your disk is 96% full and your drive reports it may fail.")
        #expect(summary.action == .freeUpSpace)
    }

    @Test func encryptionOffIsAConcernWithoutAnAction() {
        let summary = HealthChecks.summary(verdict: .excellent, checks: Self.checks(fileVault: .off))
        #expect(summary.reason == "One thing to watch: FileVault is off.")
        #expect(summary.action == nil)
    }

    @Test(arguments: [
        (MacHealthStatus.fair, "Your Mac needs some attention"),
        (.requiresAttention, "Your Mac needs some attention"),
    ])
    func middleVerdictsAskForAttention(verdict: MacHealthStatus, headline: String) {
        #expect(HealthChecks.summary(verdict: verdict, checks: Self.checks()).headline == headline)
    }

    @Test func anUnmeasuredMacIsStillBeingChecked() {
        let summary = HealthChecks.summary(verdict: nil, checks: Self.checks())
        #expect(summary == HealthSummary(headline: "Checking your Mac…", reason: "This only takes a moment.", action: nil))
    }

    // MARK: - Right now

    @Test(arguments: [
        (MemoryPressureLevel.nominal, "No memory pressure"),
        (.fair, "Some memory pressure"),
        (.critical, "High memory pressure"),
    ])
    func memoryLabelReadsThePressure(level: MemoryPressureLevel, label: String) {
        #expect(HealthChecks.memoryLoadLabel(level) == label)
    }

    @Test(arguments: [
        (0.27, "Light load"),
        (0.6, "Moderate load"),
        (0.85, "Heavy load"),
        (0.97, "Maxed out"),
    ])
    func cpuLabelReadsTheLoad(usage: Double, label: String) {
        #expect(HealthChecks.cpuLoadLabel(usage) == label)
    }

    @Test func systemLineJoinsTheFacts() {
        #expect(HealthChecks.systemLine(chip: "Apple M4 Pro", os: "macOS 27.2", uptime: "2d 17h") == "Apple M4 Pro · macOS 27.2 · Up 2d 17h")
        #expect(HealthChecks.systemLine(chip: "", os: "macOS 27.2", uptime: "5m") == "macOS 27.2 · Up 5m")
    }
}
