// AppState.swift
// Process-wide observable state — currently tracks Full Disk Access; will accumulate other app-wide flags.

import Foundation
import Observation

/// Holds app-wide state that views need to observe. Today this is just the cached
/// Full Disk Access flag; other always-needed flags (notification permission, helper
/// availability, etc.) will land here as later prompts add them.
///
/// The FDA checker is injected as a closure so tests can stub the result without
/// depending on the host machine's TCC state.
@MainActor
@Observable
final class AppState {

    private(set) var hasFullDiskAccess: Bool

    @ObservationIgnored private let checker: () -> Bool

    init(checker: @escaping () -> Bool = { PrivacyPermissionChecker.hasFullDiskAccess() }) {
        self.checker = checker
        self.hasFullDiskAccess = checker()
    }

    /// Re-runs the FDA check. Called when the app foregrounds (`scenePhase == .active`)
    /// so that granting access in System Settings reflects without a relaunch.
    func refresh() {
        hasFullDiskAccess = checker()
    }
}
