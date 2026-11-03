// ProtectionDashboardSubviews.swift
// Tiles for the Protection dashboard — the live malware-scan tile and the privacy result cards, both drawn as the shared `DashboardCard`.

import AppKit
import SwiftUI
import VaderCleanerCore

// MARK: - Malware tile

/// The lead dashboard card, driven by the malware flow's phase. While scanning
/// it shows a "Looking for Threats…" heading, a pulsing malware orb, the file
/// being scanned, and a Stop button. When the scan finishes it updates in
/// place — "No threats", a threats card with Review/Remove, or the
/// removing/done/failed states.
struct ProtectionMalwareTile: View {

    let malware: MalwareViewModel
    let role: DashboardTileRole
    let onStop: () -> Void
    let onScanAgain: () -> Void
    let onReview: () -> Void
    let onRemove: () -> Void

    var body: some View {
        DashboardCard(title: title, detail: subtitle, role: role, actions: actions) {
            DashboardOrb(symbol: "allergens", isPulsing: malware.isScanningPhase)
        } illustration: {
            VStack(spacing: 10) {
                DashboardOrb(
                    symbol: "allergens",
                    size: DashboardOrb.illustrationSize,
                    isPulsing: malware.isScanningPhase
                )
                currentFileLabel
            }
        }
    }

    @ViewBuilder
    private var currentFileLabel: some View {
        if case .scanning(let progress) = malware.phase, !progress.isEmpty {
            Text(currentFileName(progress))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("protection.malwareTile.currentFile")
        }
    }

    /// clamscan prints "<path>: <status>"; show just the file name.
    private func currentFileName(_ line: String) -> String {
        let pathPart = line.components(separatedBy: ": ").first ?? line
        let name = URL(fileURLWithPath: pathPart).lastPathComponent
        return name.isEmpty ? pathPart : name
    }

    private var actions: [DashboardCardAction] {
        switch malware.phase {
        case .checkingClamAV, .updatingDatabase, .scanning:
            return [DashboardCardAction(
                title: String(localized: "Stop", comment: "Stops the in-progress malware scan."),
                prominence: .secondary,
                identifier: "protection.malwareTile.stop",
                action: onStop
            )]
        case .results:
            return [
                DashboardCardAction(
                    title: String(localized: "Review", comment: "Opens the detected-threats list."),
                    prominence: .secondary,
                    identifier: "protection.malwareTile.review",
                    action: onReview
                ),
                DashboardCardAction(
                    title: String(localized: "Remove", comment: "Removes all detected threats."),
                    prominence: .primary,
                    identifier: "protection.malwareTile.remove",
                    action: onRemove
                ),
            ]
        case .idle, .failed, .clean, .done:
            return [DashboardCardAction(
                title: String(localized: "Scan Again", comment: "Restarts the malware scan."),
                prominence: .secondary,
                identifier: "protection.malwareTile.scanAgain",
                action: onScanAgain
            )]
        case .removing, .needsInstall:
            return []
        }
    }

    private var title: String {
        switch malware.phase {
        case .checkingClamAV, .updatingDatabase, .scanning:
            return String(localized: "Looking for Threats…", comment: "Malware tile title while scanning.")
        case .clean:
            return String(localized: "No Threats Found", comment: "Malware tile title when the scan is clean.")
        case .results(let threats):
            return ProtectionCopy.threatsFound(threats.count)
        case .removing:
            return String(localized: "Removing Threats…", comment: "Malware tile title while removing threats.")
        case .done(let count):
            return ProtectionCopy.threatsRemoved(count)
        case .failed:
            return String(localized: "Scan Failed", comment: "Malware tile title after a failure.")
        case .idle:
            return String(localized: "Scan Stopped", comment: "Malware tile title after the user stops the scan.")
        case .needsInstall:
            return ""
        }
    }

    private var subtitle: String {
        switch malware.phase {
        case .checkingClamAV, .updatingDatabase, .scanning:
            return String(localized: "Scanning your Mac in the background. This may take a moment.",
                          comment: "Malware tile subtitle while scanning.")
        case .clean:
            return malware.cleanResultDescription
        case .results:
            let advice = String(localized: "Review the detected threats and remove them to stay protected.",
                                comment: "Malware tile subtitle when threats are found.")
            return malware.unreadableNote.map { "\(advice) \($0)" } ?? advice
        case .removing:
            return String(localized: "Removing the infected files.",
                          comment: "Malware tile subtitle while removing.")
        case .done:
            return String(localized: "The infected files have been removed.",
                          comment: "Malware tile subtitle after removal.")
        case .failed(let message):
            return message
        case .idle:
            return String(localized: "The scan was stopped. Run it again whenever you want.",
                          comment: "Malware tile subtitle after stopping.")
        case .needsInstall:
            return ""
        }
    }
}

// MARK: - Privacy card

/// A dashboard card for a privacy result group (a browser's data or recent
/// items). A browser's card wears that browser's real icon, which says more
/// than a category badge; Recent Items gets an orb.
struct ProtectionPrivacyTile: View {

    let title: String
    let caption: String
    let systemImage: String
    /// The browser's app icon, once its bundle has been located.
    let appIcon: NSImage?
    let role: DashboardTileRole
    let identifier: String
    let onReview: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        DashboardCard(title: title, detail: caption, role: role, actions: actions) {
            icon(size: DashboardOrb.accessorySize)
        } illustration: {
            icon(size: DashboardOrb.illustrationSize)
        }
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            DashboardOrb(symbol: systemImage, size: size)
        }
    }

    private var actions: [DashboardCardAction] {
        var actions: [DashboardCardAction] = []
        if let onReview {
            actions.append(DashboardCardAction(
                title: String(localized: "Review", comment: "Opens the privacy manager for this group."),
                prominence: .secondary,
                identifier: "\(identifier).review",
                action: onReview
            ))
        }
        actions.append(DashboardCardAction(
            title: String(localized: "Remove", comment: "Clears this privacy group."),
            prominence: .primary,
            identifier: "\(identifier).remove",
            action: onRemove
        ))
        return actions
    }
}
