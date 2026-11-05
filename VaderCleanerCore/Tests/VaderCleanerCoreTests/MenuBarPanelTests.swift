// MenuBarPanelTests.swift
// Pins the menu bar panel's derivations: every issue that needs attention, the verdict and its ring, the detail line, the one button's priority, and when a reading is coloured.

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

    // MARK: - Primary action

    private func primary(
        protection: MenuBarViewModel.ProtectionStatus = .protected,
        scan: MenuBarViewModel.ScanActivity? = nil,
        disk: DiskStats? = nil,
        pressure: MemoryPressureLevel = .nominal,
        lastScanDate: Date? = nil,
        flush: MenuBarViewModel.MemoryFlushState = .idle
    ) -> MenuBarViewModel.PrimaryAction {
        MenuBarViewModel.primaryAction(
            protection: protection,
            scanActivity: scan,
            disk: disk ?? healthyDisk,
            pressure: pressure,
            lastScanDate: lastScanDate ?? now.addingTimeInterval(-3_600),
            flushState: flush,
            now: now
        )
    }

    /// A healthy, recently scanned Mac still gets a button, but a quiet one:
    /// the panel's one control never shouts when nothing is wrong.
    @Test func aHealthyMacGetsAQuietScanButton() {
        let action = primary()
        #expect(action.label == "Run Smart Scan")
        #expect(action.kind == .open(.smartScan, startsScan: true))
        #expect(action.style == .quiet)
        #expect(!action.isWorking)
    }

    @Test func aNeverScannedMacIsInvitedToScan() {
        let action = primary(protection: .notScanned)
        #expect(action.label == "Scan Now")
        #expect(action.kind == .open(.smartScan, startsScan: true))
        #expect(action.style == .suggested)
    }

    @Test func threatsTakeTheButton() {
        let action = primary(protection: .threatsFound, disk: lowDisk, pressure: .critical)
        #expect(action.label == "Review Threats")
        #expect(action.kind == .open(.threats, startsScan: false))
        #expect(action.style == .urgent)
    }

    @Test func aFullDiskOpensCleanup() {
        let action = primary(disk: lowDisk)
        #expect(action.kind == .open(.cleanup, startsScan: false))
        #expect(action.style == .urgent)
    }

    /// Critical memory is fixed right in the panel: the purge takes seconds,
    /// so a trip to the main window isn't worth it.
    @Test func criticalMemoryIsFreedInPlace() {
        let action = primary(pressure: .critical)
        #expect(action.kind == .flushMemory)
        #expect(action.label == "Free Memory")
        #expect(action.style == .urgent)
        #expect(!action.isWorking)
    }

    @Test func aRunningPurgeShowsItsProgress() {
        let action = primary(pressure: .critical, flush: .running)
        #expect(action.kind == .flushMemory)
        #expect(action.label == "Freeing Memory…")
        #expect(action.isWorking)
    }

    @Test func aFailedPurgeOffersARetry() {
        #expect(primary(pressure: .critical, flush: .failed).label == "Retry")
    }

    /// A running scan has no result to act on yet, so the button follows it.
    @Test func aRunningScanIsFollowed() {
        let action = primary(protection: .scanning, scan: .threatScan)
        #expect(action.kind == .showScan(.threatScan))
        #expect(action.label == "Show Scan")
        #expect(action.style == .quiet)
    }

    /// A problem the scan can't change still outranks watching its progress.
    @Test func aKnownProblemOutranksARunningScan() {
        let action = primary(protection: .scanning, scan: .smartScan, disk: lowDisk)
        #expect(action.kind == .open(.cleanup, startsScan: false))
    }

    // MARK: - Ring

    /// With nothing wrong the ring fills to the health verdict.
    @Test(arguments: MacHealthStatus.allCases)
    func theRingFillsToTheHealthVerdict(health: MacHealthStatus) {
        #expect(MenuBarViewModel.ringFraction(health: health, attention: []) == health.score)
    }

    @Test func theRingIsEmptyWhileMeasuring() {
        #expect(MenuBarViewModel.ringFraction(health: nil, attention: []) == 0)
    }

    /// An issue drains the ring however well the disk and battery look, so
    /// a full green ring can never sit above a threat.
    @Test func issuesDrainTheRing() {
        let disk = MenuBarViewModel.attentionSteps(protection: .protected, disk: lowDisk, pressure: .nominal)
        let threats = MenuBarViewModel.attentionSteps(protection: .threatsFound, disk: healthyDisk, pressure: .nominal)
        #expect(MenuBarViewModel.ringFraction(health: .excellent, attention: disk) == MacHealthStatus.requiresAttention.score)
        #expect(MenuBarViewModel.ringFraction(health: .excellent, attention: threats) == MacHealthStatus.critical.score)
        #expect(MenuBarViewModel.ringFraction(health: .critical, attention: disk) == MacHealthStatus.critical.score)
    }

    // MARK: - Readings

    /// A reading is coloured only when it is the subject of a listed issue, so
    /// the header and the numbers beneath it always agree.
    @Test func onlyAReadingWithAnIssueIsColoured() {
        let both = MenuBarViewModel.attentionSteps(protection: .protected, disk: lowDisk, pressure: .critical)
        #expect(MenuBarViewModel.readingNeedsAttention(.storage, attention: both))
        #expect(MenuBarViewModel.readingNeedsAttention(.memory, attention: both))
        #expect(!MenuBarViewModel.readingNeedsAttention(.cpu, attention: both))
        #expect(!MenuBarViewModel.readingNeedsAttention(.memory, attention: []))
    }
}
