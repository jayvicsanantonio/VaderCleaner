// MenuBarPanelTests.swift
// Pins the menu bar panel's derivations: every issue that needs attention, the header verdict and detail line, the network idle state, and when inline actions and tile colour appear.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite struct MenuBarPanelTests {

    private let healthyDisk = DiskStats(usedBytes: 400_000_000_000, totalBytes: 1_000_000_000_000)
    private let lowDisk = DiskStats(usedBytes: 950_000_000_000, totalBytes: 1_000_000_000_000)
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Attention list

    @Test func aHealthyMacHasNothingNeedingAttention() {
        let steps = MenuBarViewModel.attentionSteps(protection: .protected, disk: healthyDisk, pressure: .nominal)
        #expect(steps.isEmpty)
    }

    /// Every urgent problem is listed, worst first, so a threat never hides a
    /// nearly-full disk behind it.
    @Test func everyUrgentProblemIsListedInPriorityOrder() {
        let steps = MenuBarViewModel.attentionSteps(protection: .threatsFound, disk: lowDisk, pressure: .critical)
        #expect(steps.map(\.target) == [.threats, .cleanup, .performance])
        #expect(steps.allSatisfy { $0.urgency == .urgent })
    }

    /// A scan in flight can't report threats yet, but a full disk is still a
    /// fact worth showing beside the progress.
    @Test func aRunningScanStillReportsDiskAndMemoryProblems() {
        let steps = MenuBarViewModel.attentionSteps(protection: .scanning, disk: lowDisk, pressure: .nominal)
        #expect(steps.map(\.target) == [.cleanup])
    }

    @Test func fairMemoryPressureIsNotAnIssue() {
        let steps = MenuBarViewModel.attentionSteps(protection: .protected, disk: healthyDisk, pressure: .fair)
        #expect(steps.isEmpty)
    }

    /// The single next step stays the head of the attention list, so the two
    /// derivations can never disagree about what is most urgent.
    @Test func nextStepLeadsWithTheFirstAttentionStep() {
        let step = MenuBarViewModel.nextStep(
            protection: .protected, disk: lowDisk, pressure: .critical,
            lastScanDate: now, now: now
        )
        let first = MenuBarViewModel.attentionSteps(protection: .protected, disk: lowDisk, pressure: .critical).first
        #expect(step == first)
    }

    // MARK: - Header verdict

    /// The disk-and-battery verdict alone can read Excellent while the last
    /// scan found threats; the header must never say "at its best" above a
    /// threat.
    @Test func aThreatOverridesAGlowingHealthVerdict() throws {
        let threats = MenuBarViewModel.attentionSteps(protection: .threatsFound, disk: healthyDisk, pressure: .nominal)
        let verdict = MenuBarViewModel.panelVerdict(health: .excellent, attention: threats)
        #expect(verdict.headline == "Your Mac needs attention")
        #expect(verdict.tone == .alert)
    }

    @Test func oneNonThreatIssueReadsAsCaution() {
        let disk = MenuBarViewModel.attentionSteps(protection: .protected, disk: lowDisk, pressure: .nominal)
        let verdict = MenuBarViewModel.panelVerdict(health: .good, attention: disk)
        #expect(verdict.headline == "Your Mac needs attention")
        #expect(verdict.tone == .caution)
    }

    /// A critical health verdict keeps its stronger wording even with one
    /// listed issue.
    @Test func aCriticalVerdictKeepsItsWording() {
        let disk = MenuBarViewModel.attentionSteps(protection: .protected, disk: lowDisk, pressure: .nominal)
        let verdict = MenuBarViewModel.panelVerdict(health: .critical, attention: disk)
        #expect(verdict.headline == MenuBarViewModel.heroHeadline(for: .critical))
        #expect(verdict.tone == .alert)
    }

    @Test func severalIssuesAreCountedInTheHeadline() {
        let steps = MenuBarViewModel.attentionSteps(protection: .protected, disk: lowDisk, pressure: .critical)
        let verdict = MenuBarViewModel.panelVerdict(health: .good, attention: steps)
        #expect(verdict.headline == "2 things need attention")
        #expect(verdict.tone == .caution)
    }

    @Test func severalIssuesIncludingAThreatAreAnAlert() {
        let steps = MenuBarViewModel.attentionSteps(protection: .threatsFound, disk: lowDisk, pressure: .nominal)
        #expect(MenuBarViewModel.panelVerdict(health: .good, attention: steps).tone == .alert)
    }

    @Test(arguments: [
        (MacHealthStatus?.none, MenuBarViewModel.PanelVerdict.Tone.measuring),
        (.critical, .alert),
        (.requiresAttention, .caution),
        (.fair, .caution),
        (.good, .good),
        (.excellent, .good),
    ])
    func withNoIssuesTheHealthVerdictSetsTheTone(health: MacHealthStatus?, tone: MenuBarViewModel.PanelVerdict.Tone) {
        let verdict = MenuBarViewModel.panelVerdict(health: health, attention: [])
        #expect(verdict.headline == MenuBarViewModel.heroHeadline(for: health))
        #expect(verdict.tone == tone)
    }

    // MARK: - Header detail

    @Test func aProtectedMacNamesItsProtectionAndLastScan() {
        let detail = MenuBarViewModel.panelDetail(
            protection: .protected,
            lastScanDate: now.addingTimeInterval(-2 * 86_400),
            includesProtection: true,
            now: now
        )
        #expect(detail.hasPrefix("Protected · Last scan "))
        #expect(detail.contains("2 days ago"))
    }

    /// A never-scanned Mac says so once, not "Not scanned · No scans yet".
    @Test func aNeverScannedMacSaysSoOnce() {
        let detail = MenuBarViewModel.panelDetail(
            protection: .notScanned, lastScanDate: nil, includesProtection: true, now: now
        )
        #expect(detail == "No scans yet")
    }

    @Test func threatsAreNamedInTheDetail() {
        let detail = MenuBarViewModel.panelDetail(
            protection: .threatsFound, lastScanDate: now, includesProtection: true, now: now
        )
        #expect(detail.hasPrefix("Threats found · "))
    }

    /// Switching Protection off in Settings drops it from the header, leaving
    /// only the last-scan fact.
    @Test func hidingProtectionLeavesOnlyTheLastScan() {
        let detail = MenuBarViewModel.panelDetail(
            protection: .protected,
            lastScanDate: now.addingTimeInterval(-2 * 86_400),
            includesProtection: false,
            now: now
        )
        #expect(detail.hasPrefix("Last scan "))
        #expect(!detail.contains("Protected"))
    }

    // MARK: - Network

    /// Background chatter under a kilobyte a second reads as idle, not as a
    /// pair of identical "511 bytes/s" readings that look like a bug.
    @Test func backgroundTrafficReadsAsIdle() {
        #expect(MenuBarViewModel.networkActivity(bytesIn: 511, bytesOut: 511) == .idle)
        #expect(MenuBarViewModel.networkActivity(bytesIn: 0, bytesOut: 0) == .idle)
    }

    @Test func realTrafficShowsBothRates() {
        let activity = MenuBarViewModel.networkActivity(bytesIn: 2_000_000, bytesOut: 0)
        #expect(activity == .active(
            down: MenuBarViewModel.speedString(2_000_000),
            up: MenuBarViewModel.speedString(0)
        ))
    }

    // MARK: - Memory purge visibility

    /// Purging is offered only when memory is actually under pressure, and
    /// stays visible through its own in-flight, done, and failed feedback.
    @Test(arguments: [
        (MemoryPressureLevel.nominal, MenuBarViewModel.MemoryFlushState.idle, false),
        (.fair, .idle, true),
        (.critical, .idle, true),
        (.nominal, .running, true),
        (.nominal, .flushed, true),
        (.nominal, .failed, true),
    ])
    func memoryPurgeAppearsOnlyWhenItHelps(
        pressure: MemoryPressureLevel,
        state: MenuBarViewModel.MemoryFlushState,
        shows: Bool
    ) {
        #expect(MenuBarViewModel.showsMemoryFlush(pressure: pressure, state: state) == shows)
    }

    // MARK: - Tile colour

    /// Tiles carry colour only when a reading is off: a wall of green dots
    /// says nothing.
    @Test(arguments: [
        (StatusColor.green, StatusColor?.none),
        (.gray, nil),
        (.yellow, .yellow),
        (.red, .red),
    ])
    func onlyAbnormalReadingsAreHighlighted(status: StatusColor, highlighted: StatusColor?) {
        #expect(MenuBarViewModel.highlightedStatus(status) == highlighted)
    }

    // MARK: - Tile bars

    @Test func memoryUsedFractionIsClamped() {
        #expect(MenuBarViewModel.memoryUsedFraction(MemoryStats(usedBytes: 4, totalBytes: 16)) == 0.25)
        #expect(MenuBarViewModel.memoryUsedFraction(MemoryStats(usedBytes: 20, totalBytes: 16)) == 1)
        #expect(MenuBarViewModel.memoryUsedFraction(.empty) == 0)
    }

    @Test func cpuFractionIsClamped() {
        #expect(MenuBarViewModel.cpuFraction(0.18) == 0.18)
        #expect(MenuBarViewModel.cpuFraction(1.4) == 1)
        #expect(MenuBarViewModel.cpuFraction(-0.2) == 0)
    }
}
