// ScanCompletionNotifier.swift
// Notifies the user when a scan they started finishes, naming the section that completed.

import Foundation
import Observation
import os.log

/// Adopted by a coordinator whose `scanPresentation` reaches `.results` before
/// its scan actually finishes — e.g. a live dashboard that streams tiles in and
/// so has no separate `.working` phase. The completion notifier watches
/// `isScanComplete` for these instead of the coarse presentation, so the banner
/// fires on real completion rather than when the surface first appears.
@MainActor
protocol ScanCompletionReporting: AnyObject {
    var isScanComplete: Bool { get }
}

/// Fires a "scan complete" notification when a scan the user started reaches its
/// results, naming the section so the banner says what finished.
///
/// Notifications are *armed* explicitly at the user-facing scan entry points
/// (the floating Scan disc and the Smart Scan triggers) — never for the
/// background pre-warm scans Smart Scan kicks off — so completing a Smart Scan
/// doesn't fan out into a banner per pre-warmed section. Once armed, the
/// notifier observes the coordinator's `scanPresentation` and fires on the
/// `working → results` transition, then disarms.
@MainActor
@Observable
final class ScanCompletionNotifier {

    @ObservationIgnored private let preferences: PreferencesStore
    @ObservationIgnored private let dispatcher: NotificationDispatching
    /// Sections with a user-initiated scan in flight, keyed to the coordinator
    /// whose completion should notify.
    @ObservationIgnored private var armed: [NavigationSection: any ScanCoordinating] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "ScanCompletionNotifier")

    init(preferences: PreferencesStore, dispatcher: NotificationDispatching) {
        self.preferences = preferences
        self.dispatcher = dispatcher
    }

    /// Records that the user just started a scan for `section`, so its
    /// completion notifies. A no-op when the toggle is off. Idempotent — a
    /// re-tap just refreshes the armed coordinator.
    func armScan(section: NavigationSection, coordinator: any ScanCoordinating) {
        guard preferences.notifyScanFinished else {
            log.debug("armScan(\(section.title, privacy: .public)) ignored — notifyScanFinished is off")
            return
        }
        log.debug("Armed scan-finished notification for \(section.title, privacy: .public)")
        armed[section] = coordinator
        observe(section)
    }

    /// Re-evaluates an armed section after its coordinator changes. Internal so
    /// the firing logic is unit-testable without driving real observation.
    func evaluate(section: NavigationSection) {
        guard let coordinator = armed[section] else { return }

        // A coordinator that reaches `.results` before its work finishes reports
        // completion explicitly; watch that instead of the coarse presentation.
        if let reporter = coordinator as? ScanCompletionReporting {
            if reporter.isScanComplete {
                log.debug("Firing scan-finished notification for \(section.title, privacy: .public) (reporter complete)")
                dispatcher.sendScanFinishedNotification(scanName: section.title)
                armed[section] = nil
            } else {
                observe(section)
            }
            return
        }

        switch coordinator.scanPresentation {
        case .results:
            log.debug("Firing scan-finished notification for \(section.title, privacy: .public) (results)")
            dispatcher.sendScanFinishedNotification(scanName: section.title)
            armed[section] = nil
        case .intro:
            // The user started over / cancelled before any result — disarm.
            armed[section] = nil
        case .working:
            // Still scanning; keep watching.
            observe(section)
        }
    }

    private func observe(_ section: NavigationSection) {
        guard let coordinator = armed[section] else { return }
        withObservationTracking {
            if let reporter = coordinator as? ScanCompletionReporting {
                _ = reporter.isScanComplete
            } else {
                _ = coordinator.scanPresentation
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.evaluate(section: section) }
        }
    }
}
