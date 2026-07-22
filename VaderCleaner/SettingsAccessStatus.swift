// SettingsAccessStatus.swift
// Pure mapping from Full Disk Access and helper-daemon state to the plain-language status rows shown on the General settings tab.

import Foundation
import ServiceManagement

/// One capability row on the General tab: whether it's working, a sentence
/// explaining what that means for the user, and the button that fixes it when
/// it isn't. `actionTitle` is `nil` when there is nothing to do.
struct AccessStatusDisplay: Equatable {
    let isHealthy: Bool
    let detail: String
    let actionTitle: String?
}

/// Turns the two capabilities VaderCleaner can quietly lose — Full Disk Access
/// and the privileged helper — into rows a non-technical user can act on.
///
/// Both degrade silently today: without Full Disk Access scans simply return
/// less, and `HelperRegistration` logs a failed registration and carries on. The
/// copy therefore leads with the consequence ("scans will miss things") rather
/// than the mechanism, and never names the underlying system API.
///
/// Pure so every state's wording can be asserted in tests without touching TCC
/// or `SMAppService`.
enum SettingsAccessStatus {

    static func fullDiskAccess(hasAccess: Bool) -> AccessStatusDisplay {
        if hasAccess {
            return AccessStatusDisplay(
                isHealthy: true,
                detail: String(
                    localized: "VaderCleaner can see everything it needs to check.",
                    comment: "General settings: Full Disk Access is granted."
                ),
                actionTitle: nil
            )
        }
        return AccessStatusDisplay(
            isHealthy: false,
            detail: String(
                localized: "Without this, scans will miss things macOS keeps private.",
                comment: "General settings: Full Disk Access is not granted."
            ),
            actionTitle: String(
                localized: "Grant Access…",
                comment: "General settings: button opening the Full Disk Access pane."
            )
        )
    }

    static func helper(status: SMAppService.Status) -> AccessStatusDisplay {
        switch status {
        case .enabled:
            return AccessStatusDisplay(
                isHealthy: true,
                detail: String(
                    localized: "Ready to remove files that need your Mac's permission.",
                    comment: "General settings: the privileged helper is installed and enabled."
                ),
                actionTitle: nil
            )
        case .requiresApproval:
            return AccessStatusDisplay(
                isHealthy: false,
                detail: String(
                    localized: "Waiting for you to approve it in System Settings.",
                    comment: "General settings: the privileged helper needs user approval."
                ),
                actionTitle: String(
                    localized: "Approve…",
                    comment: "General settings: button opening Login Items so the helper can be approved."
                )
            )
        default:
            // `.notRegistered`, `.notFound`, and anything a future macOS adds:
            // the helper isn't usable and re-registering is the same fix.
            return AccessStatusDisplay(
                isHealthy: false,
                detail: String(
                    localized: "Not installed, so some cleanups will ask for your password instead.",
                    comment: "General settings: the privileged helper is missing."
                ),
                actionTitle: String(
                    localized: "Repair…",
                    comment: "General settings: button re-registering the helper."
                )
            )
        }
    }
}
