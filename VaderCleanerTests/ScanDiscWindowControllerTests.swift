// ScanDiscWindowControllerTests.swift
// Unit tests pinning that the Scan disc panel and the host-window lookup only touch AppKit windows on a later main-queue turn, never inside the SwiftUI update that asked for it.

import AppKit
import Testing
@testable import VaderCleaner
@testable import VaderCleanerCore

/// SwiftUI runs `onAppear`/`onChange` and `updateNSView` while Core Animation
/// is committing. Ordering or resizing a window from there opens a window
/// transaction mid-commit, which AppKit reports as "Invalid attempt to open a
/// new transaction during CA commit". These tests hold the deferral in place.
@MainActor
@Suite(.serialized)
struct ScanDiscWindowControllerTests {

    // MARK: - Disc panel

    @Test("showing the disc waits for the next main-queue turn")
    func showingTheDiscIsDeferred() async throws {
        let (controller, window, panel) = try await makeAttachedController()
        defer { window.close() }

        controller.setDiscVisible(true)
        #expect(panel.isVisible == false)

        await nextMainQueueTurn()
        #expect(panel.isVisible == true)
    }

    @Test("the last visibility request in a turn is the one applied")
    func lastRequestInATurnWins() async throws {
        let (controller, window, panel) = try await makeAttachedController()
        defer { window.close() }

        controller.setDiscVisible(true)
        controller.setDiscVisible(false)
        await nextMainQueueTurn()

        #expect(panel.isVisible == false)
    }

    @Test("suppressing the disc waits for the next main-queue turn")
    func suppressingTheDiscIsDeferred() async throws {
        let (controller, window, panel) = try await makeAttachedController()
        defer { window.close() }
        controller.setDiscVisible(true)
        await nextMainQueueTurn()

        controller.isSuppressed = true
        #expect(panel.isVisible == true)

        await nextMainQueueTurn()
        #expect(panel.isVisible == false)
    }

    @Test("a rail width change moves the disc on the next main-queue turn")
    func railWidthChangeIsDeferred() async throws {
        let (controller, window, panel) = try await makeAttachedController()
        defer { window.close() }
        // Smart Scan's idle content keeps reporting its Scan disc, so the
        // panel stays on screen to be repositioned; a hidden panel is placed
        // when it is next shown instead.
        controller.section = .smartScan
        controller.setDiscVisible(true)
        await nextMainQueueTurn()
        panel.contentView?.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        try #require(panel.isVisible)
        let before = panel.frame

        controller.setRailWidth(240)
        #expect(panel.frame == before)

        await nextMainQueueTurn()
        #expect(panel.frame != before)
    }

    // MARK: - Window lookup

    @Test("a resolved window is handed over on the next main-queue turn")
    func windowResolutionIsDeferred() async {
        let coordinator = WindowAccessor.Coordinator()
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var resolved: [NSWindow] = []

        coordinator.resolve(window) { resolved.append($0) }
        #expect(resolved.isEmpty)

        await nextMainQueueTurn()
        #expect(resolved.count == 1)
        #expect(resolved.first === window)
    }

    @Test("resolving the same window again hands it over only once")
    func repeatedResolutionIsDeduplicated() async {
        let coordinator = WindowAccessor.Coordinator()
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var resolvedCount = 0

        coordinator.resolve(window) { _ in resolvedCount += 1 }
        coordinator.resolve(window) { _ in resolvedCount += 1 }
        await nextMainQueueTurn()

        #expect(resolvedCount == 1)
    }

    // MARK: - Helpers

    /// Resumes once every block already queued on the main queue has run. The
    /// main queue is FIFO, so anything the code under test scheduled before
    /// this call has finished by the time it returns.
    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Builds a controller attached to an on-screen window and returns it with
    /// the disc panel hidden. Attaching to a visible window orders the child
    /// panel straight in, so the panel is hidden here first to give each test
    /// a known starting point. It shows Health Monitor, whose content reports
    /// "no disc" once on appear and never again, so the panel's own SwiftUI
    /// content can't contradict what a test asks for. The panel is returned
    /// directly because ordering a child window out also detaches it from
    /// `childWindows`.
    private func makeAttachedController() async throws -> (ScanDiscWindowController, NSWindow, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 1000, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)

        let controller = makeController()
        controller.section = .healthMonitor
        let defaults = UserDefaults(suiteName: "VaderCleanerTests.ScanDisc.\(UUID().uuidString)")!
        controller.attach(
            to: window,
            railWidth: 72,
            appState: AppState(checker: { true }),
            scanCompletionNotifier: ScanCompletionNotifier(
                preferences: PreferencesStore(defaults: defaults),
                dispatcher: NotificationManager(authorizationRequester: { true })
            )
        )
        let panel = try #require(window.childWindows?.first)
        // Lay the content out now so Health Monitor's one-time report lands
        // here rather than in the middle of a test.
        panel.contentView?.layoutSubtreeIfNeeded()
        controller.setDiscVisible(false)
        await nextMainQueueTurn()
        try #require(!panel.isVisible)
        return (controller, window, panel)
    }

    /// A controller over seven view models whose collaborators all return
    /// empty results, so every section sits idle at its intro.
    private func makeController() -> ScanDiscWindowController {
        ScanDiscWindowController(
            smartScanViewModel: SmartScanViewModel(
                scanEngine: { _, _ in
                    CarePlan(
                        findings: [],
                        health: nil,
                        unitOutcomes: [:],
                        startedAt: Date(timeIntervalSinceReferenceDate: 0),
                        finishedAt: Date(timeIntervalSinceReferenceDate: 1)
                    )
                },
                junkCleaner: { _ in 0 }
            ),
            systemJunkViewModel: SystemJunkViewModel(
                scanner: { _ in ScanResult(items: []) },
                deleter: { _ in 0 }
            ),
            myClutterViewModel: MyClutterViewModel(
                duplicateScan: { _ in [] },
                similarScan: { _ in [] },
                largeOldScan: { _ in [] },
                downloadsScan: { _ in [] },
                deleter: { Set($0) }
            ),
            spaceLensViewModel: DiskScannerViewModel(scanner: { _, _ in
                DiskNode(url: URL(fileURLWithPath: "/tmp"), name: "tmp", size: 0, isDirectory: true, children: [])
            }),
            performanceViewModel: PerformanceViewModel(
                loadLoginItems: { [] },
                loadUserAgents: { [] },
                loadSystemAgents: { [] },
                readMemory: { .empty },
                setLoginItemEnabled: { _, _ in },
                disableAgent: { _ in },
                enableAgent: { _ in },
                removeAgent: { _ in },
                flushRAM: {},
                runMaintenance: { "" },
                launchAtLoginChanges: nil
            ),
            protectionViewModel: makeProtectionViewModel(),
            applicationsViewModel: ApplicationsViewModel(
                discoverApps: { [] },
                checkUpdates: { _ in [] },
                scanInstallationFiles: { [] },
                scanUnsupportedApps: { _ in [] },
                scanUnusedApps: { _ in [] },
                scanLeftovers: { _ in [] },
                recycleFiles: { _ in [] }
            )
        )
    }

    /// A Protection dashboard whose malware and privacy collaborators all
    /// report nothing, so it sits idle at its intro.
    private func makeProtectionViewModel() -> ProtectionDashboardViewModel {
        ProtectionDashboardViewModel(
            malware: MalwareViewModel(
                checkInstalled: { true },
                databaseLastUpdated: { Date() },
                updateDatabase: { _ in },
                scan: { _, _ in [] },
                removeThreats: { _ in [] },
                notify: { _ in },
                shouldNotify: { false }
            ),
            privacy: PrivacyViewModel(
                detector: { [] },
                sizer: { _, _ in 0 },
                pathsFor: { _, _ in [] },
                clearer: { _, _ in },
                clearRecentFiles: {}
            ),
            protectionPrivacy: ProtectionPrivacyModel(
                detect: { [] },
                count: { _, _ in 0 },
                items: { _, _ in [] },
                remove: { _ in }
            )
        )
    }
}
