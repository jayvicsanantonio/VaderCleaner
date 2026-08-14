// WelcomeViewModel.swift
// Drives the first-run welcome flow — step navigation, live Full Disk Access detection, and the hand-off into the user's first Smart Scan.

import Foundation
import AppKit
import Observation

/// The state machine behind `WelcomeView`.
///
/// Collaborators are injected as closures with a `live()` production factory,
/// the same shape as the section view models, so the flow can be driven in
/// tests without touching the host's TCC state or launching System Settings.
@MainActor
@Observable
final class WelcomeViewModel {

    /// The step currently on screen. Restored from the store rather than
    /// pinned to `.first`, because granting Full Disk Access makes macOS quit
    /// the app out from under this flow.
    private(set) var step: WelcomeStep

    /// Whether the flow should be covering the window. Starts `false` for a
    /// user who has already been through it, so the app opens straight into
    /// the main window.
    private(set) var isPresented: Bool

    /// Latest Full Disk Access reading. The access step polls this so a grant
    /// that takes effect without a restart is noticed on its own.
    private(set) var hasFullDiskAccess: Bool

    /// Whether the user has been sent to System Settings at least once.
    ///
    /// macOS only applies Full Disk Access to a process that starts *after*
    /// the grant, and offers to quit the app to make that happen. A user who
    /// declines that offer has genuinely granted the permission while this
    /// process still cannot see it — so the step would sit on "Waiting for
    /// access…" indefinitely and look broken. This flag lets it say what is
    /// actually going on instead.
    private(set) var hasVisitedSystemSettings = false

    /// Whether the one-time pointer at the floating Scan disc should be on
    /// screen. Raised only for a user who closed the flow without starting a
    /// scan — someone who chose "Run First Smart Scan" can already see the
    /// disc working, and pointing at it would explain something they are
    /// watching happen.
    private(set) var isShowingScanHint = false

    /// Called once, when the flow closes. The flag says whether the user asked
    /// for their first Smart Scan to start immediately.
    var onFinish: ((_ startScan: Bool) -> Void)?

    @ObservationIgnored private let store: WelcomeStore
    @ObservationIgnored private let fullDiskAccessChecker: () -> Bool
    @ObservationIgnored private let openSystemSettingsAction: () -> Void

    init(
        store: WelcomeStore,
        fullDiskAccessChecker: @escaping () -> Bool,
        openSystemSettings: @escaping () -> Void
    ) {
        self.store = store
        self.fullDiskAccessChecker = fullDiskAccessChecker
        self.openSystemSettingsAction = openSystemSettings
        self.isPresented = !store.hasCompletedWelcome
        self.hasFullDiskAccess = fullDiskAccessChecker()
        self.step = store.resumeStep ?? .first
    }

    /// Production wiring: the real TCC probe and the real System Settings
    /// deep-link, which is the same URL the standalone FDA sheet uses.
    static func live(store: WelcomeStore = WelcomeStore()) -> WelcomeViewModel {
        WelcomeViewModel(
            store: store,
            fullDiskAccessChecker: { PrivacyPermissionChecker.hasFullDiskAccess() },
            openSystemSettings: {
                NSWorkspace.shared.open(PermissionOnboardingViewModel.systemSettingsURL)
            }
        )
    }

    // MARK: Navigation

    /// Whether there is a step behind the current one.
    var canGoBack: Bool { step.previous != nil }

    /// Whether the tour is still ahead, and so still skippable.
    var canSkipTour: Bool { step.rawValue < WelcomeStep.access.rawValue }

    /// Moves to the next step. Holds on the last step rather than dismissing —
    /// the flow closes only through `finish(startingScan:)`, so the user always
    /// makes that choice explicitly.
    func advance() {
        guard let next = step.next else { return }
        moveTo(next)
    }

    func back() {
        guard let previous = step.previous else { return }
        moveTo(previous)
    }

    /// Jumps past the three capability stops to the permission step. A no-op
    /// once the tour is behind the user, so a stray keyboard shortcut can't
    /// send them backwards.
    func skipTour() {
        guard canSkipTour else { return }
        moveTo(.access)
    }

    /// Every move goes through here so the resume point can never drift from
    /// what is on screen.
    private func moveTo(_ destination: WelcomeStep) {
        step = destination
        store.recordStep(destination)
    }

    // MARK: Full Disk Access

    /// Re-probes Full Disk Access. Called on a slow poll while the access step
    /// is showing, and whenever the app comes back to the foreground.
    func refreshAccess() {
        hasFullDiskAccess = fullDiskAccessChecker()
    }

    /// Opens System Settings on the Full Disk Access pane, and records the
    /// visit so the step can explain the restart if the reading stays false.
    func requestFullDiskAccess() {
        hasVisitedSystemSettings = true
        openSystemSettingsAction()
    }

    // MARK: Finishing

    /// Closes the flow for good. Idempotent — a double-click on the finish
    /// button must not start two scans.
    func finish(startingScan: Bool) {
        guard isPresented else { return }
        isPresented = false
        store.markCompleted()
        if !startingScan, !store.hasSeenScanHint {
            isShowingScanHint = true
        }
        onFinish?(startingScan)
    }

    /// Puts the Scan-disc pointer away and remembers that it has been shown.
    /// A no-op when nothing is showing, so a stray dismissal — a click that
    /// lands elsewhere, a scan the user started on their own — cannot spend
    /// the one hint they get before they have actually seen it.
    func dismissScanHint() {
        guard isShowingScanHint else { return }
        isShowingScanHint = false
        store.markScanHintSeen()
    }
}
