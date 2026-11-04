// CareFindingRowCopy.swift
// The results feed's compact copy: a one-line summary per finding kind, the amount a ready row shows, and the picked note on a your-call card.

import Foundation

/// A ready row's amount: what Fix takes, and — only when that falls short of
/// what the scan found — a quieter second line saying so.
public struct CareRowAmount: Equatable, Sendable {
    public let primary: String
    public let secondary: String?
}

extension CareFindingCopy {

    /// One short line per kind, for rows too compact for the full
    /// explanation. The explanation still opens the Review screen.
    public static func summary(for kind: CareFinding.Kind) -> String {
        switch kind {
        case .threats:
            return String(localized: "Harmful files found on this Mac", bundle: .module, comment: "Results row summary: malware.")
        case .lowDiskSpace:
            return String(localized: "Your startup disk is nearly full", bundle: .module, comment: "Results row summary: low disk space.")
        case .junkCleanup:
            return String(localized: "Caches, logs, and temporary files", bundle: .module, comment: "Results row summary: system junk.")
        case .duplicates:
            return String(localized: "Extra copies in Downloads — originals kept", bundle: .module, comment: "Results row summary: duplicate files.")
        case .largeOldFiles:
            return String(localized: "Big files you haven't opened in a while", bundle: .module, comment: "Results row summary: large and old files.")
        case .unusedApps:
            return String(localized: "Apps you haven't opened in months", bundle: .module, comment: "Results row summary: unused apps.")
        case .appLeftovers:
            return String(localized: "Support files from apps you've removed", bundle: .module, comment: "Results row summary: app leftovers.")
        case .installers:
            return String(localized: "Installers for apps you already have", bundle: .module, comment: "Results row summary: finished installers.")
        case .appUpdates:
            return String(localized: "Newer versions with fixes and security updates", bundle: .module, comment: "Results row summary: app updates.")
        case .maintenanceDue:
            return String(localized: "Housekeeping like refreshing system caches", bundle: .module, comment: "Results row summary: maintenance tasks.")
        case .browserPrivacy:
            return String(localized: "Cookies, history, and other browsing traces", bundle: .module, comment: "Results row summary: browser privacy.")
        case .loginItems:
            return String(localized: "Apps that open when you log in", bundle: .module, comment: "Results row summary: login items.")
        case .similarImages:
            return String(localized: "Bursts and near-duplicate photos", bundle: .module, comment: "Results row summary: similar photos.")
        case .downloads:
            return String(localized: "Downloads you opened once and forgot", bundle: .module, comment: "Results row summary: old downloads.")
        case .unsupportedApps:
            return String(localized: "Apps this version of macOS can't run", bundle: .module, comment: "Results row summary: unsupported apps.")
        case .extensions:
            return String(localized: "Add-ons installed in browsers and apps", bundle: .module, comment: "Results row summary: extensions.")
        case .backgroundItems:
            return String(localized: "Helpers that keep running in the background", bundle: .module, comment: "Results row summary: background items.")
        }
    }

    /// A ready row's amount. It leads with what Fix takes, so the row agrees
    /// with the hero's total, and adds what was found only when the two
    /// differ — a fully selected row needs no second number.
    public static func rowAmount(for finding: CareFinding, selectedBytes: Int64, selectedCount: Int) -> CareRowAmount {
        let noneSelected = String(localized: "None selected", bundle: .module, comment: "Care tile secondary line when nothing in the finding is selected.")
        guard finding.reclaimableBytes > 0 else {
            let secondary: String?
            if selectedCount == 0 {
                secondary = noneSelected
            } else if selectedCount < finding.itemCount {
                secondary = String.localizedStringWithFormat(
                    String(localized: "%d selected", bundle: .module, comment: "Care tile secondary line: selected item count."),
                    selectedCount
                )
            } else {
                secondary = nil
            }
            return CareRowAmount(primary: metric(for: finding), secondary: secondary)
        }
        guard selectedCount > 0 else {
            return CareRowAmount(primary: metric(for: finding), secondary: noneSelected)
        }
        guard selectedBytes < finding.reclaimableBytes else {
            return CareRowAmount(primary: formattedBytes(finding.reclaimableBytes), secondary: nil)
        }
        return CareRowAmount(
            primary: formattedBytes(selectedBytes),
            secondary: String.localizedStringWithFormat(
                String(localized: "of %@ found", bundle: .module, comment: "Results row secondary line: the total the scan found, under the selected amount."),
                formattedBytes(finding.reclaimableBytes)
            )
        )
    }

    /// A your-call card's status: nothing is chosen until the user picks, so
    /// the empty state says so rather than reading "0".
    public static func pickedNote(hasSize: Bool, selectedBytes: Int64, selectedCount: Int) -> String {
        guard selectedCount > 0 else {
            return String(localized: "Nothing picked yet", bundle: .module, comment: "Your-call card status before the user chooses anything.")
        }
        if hasSize {
            return String.localizedStringWithFormat(
                String(localized: "%@ picked", bundle: .module, comment: "Your-call card status: bytes the user chose."),
                formattedBytes(selectedBytes)
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "%d picked", bundle: .module, comment: "Your-call card status: items the user chose."),
            selectedCount
        )
    }
}
