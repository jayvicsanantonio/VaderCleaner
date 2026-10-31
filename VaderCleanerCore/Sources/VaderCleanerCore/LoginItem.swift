// LoginItem.swift
// Login-item model and SMAppService-backed manager for the Performance feature's Login Items section.

import Foundation
import ServiceManagement

/// A single managed login item shown in the Performance view.
public struct LoginItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isEnabled: Bool
    /// `true` when launchd holds the registration but it is not yet active —
    /// the user must finish enabling it in System Settings → Login Items.
    /// SMAppService reports this as `.requiresApproval`; it is treated as
    /// enabled so a fresh `register()` doesn't read as "off", while the view
    /// shows a "finish in System Settings" hint.
    public let requiresApproval: Bool

    public init(id: String, name: String, isEnabled: Bool, requiresApproval: Bool = false) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.requiresApproval = requiresApproval
    }
}

/// Surfaces login items through `SMAppService`.
///
/// macOS exposes no public API to *enumerate* login items registered by other
/// applications — `SMAppService` can only report the status of the host app's
/// own registration (`SMAppService.mainApp`). Third-party "open at login"
/// agents physically live in `~/Library/LaunchAgents` and are surfaced by
/// `LaunchAgentManager` instead. This manager therefore covers exactly what
/// `SMAppService` can truthfully report: the host app itself, and only while it
/// is registered, since an app that doesn't open at login isn't a login item.
/// The status is injected as a closure so tests never read real login-item
/// state.
///
/// It only reads. Registering or unregistering the host app goes through
/// `PreferencesStore` — its `launchAtLogin` setter, or `setLaunchAtLogin(_:)`
/// for a caller that shows its own error — which writes to launchd off the
/// main actor one change at a time and reverts the toggle when a write fails.
struct LoginItemsManager: Sendable {

    typealias StatusProvider = @Sendable () -> SMAppService.Status

    private let displayName: String
    private let identifier: String
    private let statusProvider: StatusProvider

    init(
        displayName: String,
        identifier: String,
        statusProvider: @escaping StatusProvider
    ) {
        self.displayName = displayName
        self.identifier = identifier
        self.statusProvider = statusProvider
    }

    /// The host app's login item, reflecting the live `SMAppService` status so
    /// a change made in System Settings → Login Items is picked up on refresh.
    /// Empty when the host app isn't registered.
    func items() -> [LoginItem] {
        let status = statusProvider()
        guard status == .enabled || status == .requiresApproval else { return [] }
        return [
            LoginItem(
                id: identifier,
                name: displayName,
                // `.requiresApproval` means launchd holds the registration but
                // it is not active yet; treat it as enabled so a fresh
                // `register()` — which lands in `.requiresApproval` pending the
                // user's approval — doesn't snap the toggle back to off.
                isEnabled: true,
                requiresApproval: status == .requiresApproval
            )
        ]
    }
}

extension LoginItemsManager {

    /// Production manager reading the live status of `SMAppService.mainApp`,
    /// the same registration the Preferences "Launch at Login" control writes.
    static func live() -> LoginItemsManager {
        LoginItemsManager(
            displayName: Bundle.main.infoDictionary?["CFBundleName"] as? String
                ?? "VaderCleaner",
            identifier: Bundle.main.bundleIdentifier ?? "com.personal.VaderCleaner",
            statusProvider: { SMAppService.mainApp.status }
        )
    }
}
