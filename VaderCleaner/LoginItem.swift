// LoginItem.swift
// Login-item model and SMAppService-backed manager for the Optimization feature's Login Items section.

import Foundation
import ServiceManagement

/// A single managed login item shown in the Optimization view.
struct LoginItem: Identifiable, Equatable {
    let id: String
    let name: String
    let isEnabled: Bool
}

/// Surfaces and toggles login items through `SMAppService`.
///
/// macOS exposes no public API to *enumerate* login items registered by other
/// applications — `SMAppService` can only report the status of the host app's
/// own registration (`SMAppService.mainApp`). Third-party "open at login"
/// agents physically live in `~/Library/LaunchAgents` and are surfaced by
/// `LaunchAgentManager` instead. This manager therefore covers exactly what
/// `SMAppService` can truthfully report: the host app itself. Collaborators
/// are injected as closures so tests never mutate real login-item state.
struct LoginItemsManager {

    typealias StatusProvider = () -> SMAppService.Status
    typealias SetEnabledHandler = (Bool) throws -> Void

    private let displayName: String
    private let identifier: String
    private let statusProvider: StatusProvider
    private let setEnabledHandler: SetEnabledHandler

    init(
        displayName: String,
        identifier: String,
        statusProvider: @escaping StatusProvider,
        setEnabledHandler: @escaping SetEnabledHandler
    ) {
        self.displayName = displayName
        self.identifier = identifier
        self.statusProvider = statusProvider
        self.setEnabledHandler = setEnabledHandler
    }

    /// The host app's login item, reflecting the live `SMAppService` status so
    /// a change made in System Settings → Login Items is picked up on refresh.
    func items() -> [LoginItem] {
        [
            LoginItem(
                id: identifier,
                name: displayName,
                isEnabled: statusProvider() == .enabled
            )
        ]
    }

    /// Registers or unregisters the host app as a login item.
    func setEnabled(_ enabled: Bool, for item: LoginItem) throws {
        try setEnabledHandler(enabled)
    }
}

extension LoginItemsManager {

    /// Production manager bound to `SMAppService.mainApp` via the existing
    /// idempotent `LoginItemManager` wrapper, so toggling here behaves exactly
    /// like the Preferences "Launch at Login" control.
    static func live() -> LoginItemsManager {
        LoginItemsManager(
            displayName: Bundle.main.infoDictionary?["CFBundleName"] as? String
                ?? "VaderCleaner",
            identifier: Bundle.main.bundleIdentifier ?? "com.personal.VaderCleaner",
            statusProvider: { SMAppService.mainApp.status },
            setEnabledHandler: { try LoginItemManager.setEnabled($0) }
        )
    }
}
