// AppState.swift
// Process-wide observable state — currently tracks Full Disk Access; will accumulate other app-wide flags.

import AppKit
import Observation

/// Holds app-wide state that views need to observe — currently just the cached
/// Full Disk Access flag and the trip to System Settings to change it. This is
/// the home for a flag that more than one section needs; anything owned by a
/// single screen belongs on that screen's view model instead.
///
/// The FDA checker is injected as a closure so tests can stub the result without
/// depending on the host machine's TCC state.
@MainActor
@Observable
public final class AppState {

    public private(set) var hasFullDiskAccess: Bool

    /// Set once the user has been sent to System Settings from any surface, so
    /// those surfaces can stop pointing back there and offer the relaunch instead.
    private var hasVisitedFullDiskAccessSettings = false

    /// Whether the user has been to System Settings and access still reads false.
    /// macOS only applies Full Disk Access to a process started after the grant,
    /// and nothing readable from this process can tell "granted, not applied yet"
    /// from "not granted", so this is the honest moment to offer a relaunch.
    public var isAwaitingRelaunchForFullDiskAccess: Bool {
        hasVisitedFullDiskAccessSettings && !hasFullDiskAccess
    }

    @ObservationIgnored private let checker: () -> Bool
    @ObservationIgnored private let openFullDiskAccessSettingsAction: () -> Void
    @ObservationIgnored private let relaunchAction: () -> Void

    public init(
        checker: @escaping () -> Bool = { PrivacyPermissionChecker.hasFullDiskAccess() },
        openFullDiskAccessSettings: @escaping () -> Void = {
            NSWorkspace.shared.open(PrivacyPermissionChecker.fullDiskAccessSettingsURL)
        },
        relaunch: @escaping () -> Void = {
            Task { @MainActor in await AppRelauncher.relaunch() }
        }
    ) {
        self.checker = checker
        self.openFullDiskAccessSettingsAction = openFullDiskAccessSettings
        self.relaunchAction = relaunch
        self.hasFullDiskAccess = checker()
    }

    /// Re-runs the FDA check. Called when the app foregrounds (`scenePhase == .active`)
    /// so that granting access in System Settings reflects without a relaunch
    /// whenever macOS applies it to the running process.
    public func refresh() {
        hasFullDiskAccess = checker()
    }

    /// Opens System Settings on the Full Disk Access pane and records the visit.
    public func openFullDiskAccessSettings() {
        hasVisitedFullDiskAccessSettings = true
        openFullDiskAccessSettingsAction()
    }

    /// Replaces this process with a new one, which picks up a grant macOS won't
    /// apply to the running one.
    public func relaunch() {
        relaunchAction()
    }
}
