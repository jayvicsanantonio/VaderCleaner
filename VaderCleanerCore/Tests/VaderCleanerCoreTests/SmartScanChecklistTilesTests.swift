// SmartScanChecklistTilesTests.swift
// Pins the scanning screen's tiles: which domains get one, in bento slot order, and how Protection's tile also reports the browsing-traces check that has no tile of its own.

import Foundation
import Testing
@testable import VaderCleanerCore

@MainActor
@Suite
struct SmartScanChecklistTilesTests {

    // MARK: - Which tiles, in what order

    @Test
    func browserPrivacyHasNoTileOfItsOwn() {
        let vm = SmartScanViewModel(scanEngine: { _, _ in Self.plan() })

        #expect(!vm.checklistDomains.contains(.browserPrivacy))
    }

    /// The tiles fill the shared dashboard bento — lead, wide, pair, wide — so
    /// Applications and Performance, whose result lines run longest, land in
    /// the two wide slots.
    @Test
    func tilesFollowTheBentoSlotOrder() {
        let vm = SmartScanViewModel(scanEngine: { _, _ in Self.plan() })

        #expect(vm.checklistDomains == [.systemJunk, .applications, .myClutter, .malware, .performance])
    }

    // MARK: - Protection covers browsing traces

    @Test
    func protectionKeepsCheckingWhileBrowsingTracesAreCounted() async {
        let gate = TileTestGate()
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitFinished(.malware, .completed, nil))
            onEvent(.unitStarted(.browserPrivacy))
            onEvent(.unitProgress(.browserPrivacy, 7))
            await gate.wait()
            return Self.plan()
        })
        let scan = Task { await vm.scan() }

        #expect(await pollUntil { vm.domainStatus(.malware) == .running(itemsScanned: 7) })

        await gate.open()
        _ = await scan.value
    }

    @Test
    func protectionResultLineAddsTheBrowsingTracesFound() async {
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitFinished(.malware, .completed, nil))
            onEvent(.unitFinished(.browserPrivacy, .completed, Self.traces(15)))
            try? await Task.sleep(for: .milliseconds(100))
            return Self.plan()
        })
        await vm.scan()

        #expect(vm.domainStatus(.malware) == .finished(line: "No threats found · 15 browsing traces"))
    }

    /// A clean browser history is no news next to the threat check's own
    /// all-clear, so it doesn't lengthen the line.
    @Test
    func protectionResultLineLeavesOutAnEmptyBrowsingTracesCheck() async {
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitFinished(.malware, .completed, nil))
            onEvent(.unitFinished(.browserPrivacy, .completed, nil))
            try? await Task.sleep(for: .milliseconds(100))
            return Self.plan()
        })
        await vm.scan()

        #expect(vm.domainStatus(.malware) == .finished(line: "No threats found"))
    }

    /// With the threat check off in Settings, the tile must not claim "No
    /// threats found" — it reports only what it did check.
    @Test
    func protectionResultLineSpeaksOnlyForChecksThatRan() async {
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitFinished(.malware, .skipped(.disabledInSettings), nil))
            onEvent(.unitFinished(.browserPrivacy, .completed, nil))
            try? await Task.sleep(for: .milliseconds(100))
            return Self.plan()
        })
        await vm.scan()

        #expect(vm.domainStatus(.malware) == .finished(line: "No browsing traces found"))
    }

    @Test
    func protectionIsSkippedOnlyWhenBothChecksAre() async {
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitFinished(.malware, .skipped(.disabledInSettings), nil))
            onEvent(.unitFinished(.browserPrivacy, .skipped(.disabledInSettings), nil))
            try? await Task.sleep(for: .milliseconds(100))
            return Self.plan()
        })
        await vm.scan()

        #expect(vm.domainStatus(.malware) == .skipped)
    }

    @Test
    func protectionShowsAFailedBrowsingTracesCheck() async {
        let vm = SmartScanViewModel(scanEngine: { _, onEvent in
            onEvent(.unitFinished(.malware, .completed, nil))
            onEvent(.unitFinished(.browserPrivacy, .failed(message: "unreadable"), nil))
            try? await Task.sleep(for: .milliseconds(100))
            return Self.plan()
        })
        await vm.scan()

        #expect(vm.domainStatus(.malware) == .failed)
    }

    // MARK: - Fixtures

    private nonisolated static func plan() -> CarePlan {
        CarePlan(
            findings: [],
            health: nil,
            unitOutcomes: [:],
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
    }

    private nonisolated static func traces(_ count: Int) -> CareFinding {
        CareFinding(payload: .browserPrivacy([
            BrowserPrivacySummary(browser: .safari, counts: [.cookies: count])
        ]))
    }
}

/// Holds a fake scan open until the test lets it finish.
private actor TileTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
