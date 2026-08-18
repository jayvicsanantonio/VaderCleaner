// ProtectionDashboardViewModel.swift
// Thin coordinator for the Protection results dashboard — runs the malware scan and the privacy preview together and drives the unified intro → dashboard flow.

import Foundation
import Observation
import os

/// Coordinates the Protection section's dashboard, which shows a live
/// malware-scan tile alongside privacy result tiles. It owns no scan logic of
/// its own: it composes the existing `MalwareViewModel` and `PrivacyViewModel`
/// so the dashboard reuses both feature flows untouched.
///
/// The section's coarse phase is gated on `hasScanned` rather than the malware
/// view-model's idle state, so tapping **Stop** on the malware tile (which
/// returns the malware flow to idle) leaves the dashboard — and its privacy
/// tiles — in place. The dashboard also reappears when the malware flow already
/// holds a result (e.g. seeded from a Smart Scan), so navigating to Protection
/// after a Smart Scan still shows the findings.
@MainActor
@Observable
final class ProtectionDashboardViewModel {

    @ObservationIgnored let malware: MalwareViewModel
    @ObservationIgnored let privacy: PrivacyViewModel
    /// Backs the Protection Manager's Privacy pane (per-browser categories,
    /// per-item rows, real counts). Separate from `privacy` (which feeds the
    /// dashboard tiles) and scanned lazily when the manager opens.
    @ObservationIgnored let protectionPrivacy: ProtectionPrivacyModel

    /// True once the user has started a Protection scan from this dashboard.
    /// Drives `scanPresentation` so the grid stays up across the malware
    /// flow's own idle transitions (Stop, clean, etc.).
    private(set) var hasScanned = false

    @ObservationIgnored private let log = Logger(subsystem: "com.personal.VaderCleaner",
                                                 category: "ProtectionDashboardViewModel")

    init(
        malware: MalwareViewModel,
        privacy: PrivacyViewModel,
        protectionPrivacy: ProtectionPrivacyModel
    ) {
        self.malware = malware
        self.privacy = privacy
        self.protectionPrivacy = protectionPrivacy
    }

    /// Starts both scans together. The privacy preview is fast and fills its
    /// tiles in while the slower malware scan keeps streaming, which is what
    /// makes the grid populate as each tile becomes ready.
    func beginScan() {
        hasScanned = true
        malware.beginScan()
        privacy.beginScan()
        prewarmManagerPrivacy()
    }

    /// Populates the dashboard from a completed Smart Scan so the user never has
    /// to scan Protection by hand afterwards. The malware tile is seeded from the
    /// scan's own results (no re-scan), and the fast privacy preview is kicked off
    /// so its tiles are ready too — unlike `beginScan()`, which would redundantly
    /// re-run the malware scan. A no-op once the user has scanned here, so it
    /// never disrupts a scan they started themselves.
    func prewarmFromSmartScan(threats: [MalwareThreat], clamAVAvailable: Bool, scannedAt date: Date) {
        guard !hasScanned else { return }
        // The privacy preview doesn't depend on the malware engine, so it is
        // warmed either way — its tiles and the manager are ready whenever the
        // user arrives.
        if case .idle = privacy.phase { privacy.beginScan() }
        prewarmManagerPrivacy()
        // Only a seed that can actually land counts as "this section has been
        // scanned". A Smart Scan that never ran the malware unit — Protection
        // switched off in Smart Care, an unusable engine, a failed scan — has no
        // result to show, and claiming otherwise replaced the section's intro
        // with a dashboard whose malware tile read "Scan Stopped" for a scan the
        // user never started. `hasScanned` is one-shot, so setting it here would
        // also spend the one chance a later Smart Scan has to seed properly.
        guard clamAVAvailable else { return }
        hasScanned = true
        malware.seed(threats: threats, clamAVAvailable: clamAVAvailable, scannedAt: date)
    }

    // MARK: - Tile removal

    /// Why the last tile removal failed, or `nil` when nothing has. The tile's
    /// Remove sits behind a "this cannot be undone" confirmation, so a failure
    /// that left the tile in place and said nothing read as a broken button.
    private(set) var removalFailureMessage: String?

    /// Clears one browser's privacy data for its dashboard tile. Returns whether
    /// the data is gone, so the caller can retire the tile — a tile whose data
    /// is still there must stay, and the reason surfaces instead.
    func clearPrivacyData(for browser: Browser) async -> Bool {
        await removing { try await privacy.clearData(for: browser) }
    }

    /// The same for the Recent Items tile.
    func clearRecentItems() async -> Bool {
        await removing { try await privacy.clearRecentItems() }
    }

    /// Dismisses the failure alert, so a retry starts from a clean slate rather
    /// than leaving a stale reason behind a later success.
    func dismissRemovalFailure() {
        removalFailureMessage = nil
    }

    private func removing(_ work: () async throws -> Void) async -> Bool {
        removalFailureMessage = nil
        do {
            try await work()
            return true
        } catch {
            log.error("Protection tile removal failed: \(String(describing: error), privacy: .private)")
            removalFailureMessage = error.localizedDescription
            return false
        }
    }

    /// Warms the Protection Manager's privacy model alongside the dashboard scan
    /// so the manager opens already populated (per-browser categories, per-item
    /// rows, real counts) instead of blank. Gated on `.idle` so it runs once and
    /// reuses the cached result on later scans — matching how the manager itself
    /// caches its first scan.
    private func prewarmManagerPrivacy() {
        guard protectionPrivacy.phase == .idle else { return }
        Task { await protectionPrivacy.scan() }
    }

    /// Resets both flows to idle and returns the section to its intro screen.
    func startOver() {
        // `cancel()` returns the malware flow to idle from any phase (scanning,
        // results, clean, done, failed); `scanAgain()` is privacy's public
        // reset. Clearing `hasScanned` flips `scanPresentation` back to `.intro`.
        malware.cancel()
        privacy.scanAgain()
        hasScanned = false
    }

    /// Whether the malware flow currently holds a result the dashboard should
    /// surface even before the user scanned here (a Smart Scan seed).
    private var malwareHasResult: Bool {
        switch malware.phase {
        case .results, .clean, .done:
            return true
        default:
            return false
        }
    }

    /// Whether the malware scan has settled into a non-scanning state — a real
    /// result, a clean bill, a finished removal, a failure, or "needs install"
    /// (ClamAV absent, so nothing more will happen).
    private var malwareSettled: Bool {
        switch malware.phase {
        case .results, .clean, .done, .failed, .needsInstall:
            return true
        case .idle, .checkingClamAV, .updatingDatabase, .scanning, .removing:
            return false
        }
    }

    /// Whether the privacy preview has settled (finished previewing, cleared, or
    /// failed) rather than still being in flight.
    private var privacySettled: Bool {
        switch privacy.phase {
        case .preview, .complete, .failed:
            return true
        case .idle, .scanning, .clearing:
            return false
        }
    }
}

// MARK: - ScanCompletionReporting

extension ProtectionDashboardViewModel: ScanCompletionReporting {

    /// True once a scan started here has finished both halves — the malware scan
    /// and the privacy preview. The dashboard's `scanPresentation` reaches
    /// `.results` the moment scanning starts (it streams tiles in), so the scan-
    /// finished banner keys off this instead.
    var isScanComplete: Bool {
        hasScanned && malwareSettled && privacySettled
    }
}

// MARK: - ScanCoordinating

extension ProtectionDashboardViewModel: ScanCoordinating {

    /// `.intro` until a scan has been started here (or the malware flow already
    /// carries a result); otherwise the dashboard. We never report `.working`:
    /// the dashboard *is* the working surface, so it shows immediately instead
    /// of a full-screen progress screen.
    var scanPresentation: ScanPresentation {
        (hasScanned || malwareHasResult) ? .results : .intro
    }
}
