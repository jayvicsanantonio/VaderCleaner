// ProtectionDashboardSubviews.swift
// Tiles for the Protection dashboard — the live malware-scan tile and the privacy result cards, sharing the Applications dashboard's glass-card styling.

import SwiftUI

// MARK: - Malware tile

/// The lead dashboard card, driven by the malware flow's phase. While scanning
/// it reproduces the reference: a "Looking for Threats…" heading, a biohazard
/// hero, the current file being scanned, and a Stop button. When the scan
/// finishes it updates in place — "No threats", a threats card with
/// Review/Remove, or the removing/done/failed states. Shares the app-wide
/// dashboard tile chrome (`vaderTileGlass`).
struct ProtectionMalwareTile: View {

    let malware: MalwareViewModel
    let accent: Color
    let onStop: () -> Void
    let onScanAgain: () -> Void
    let onReview: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("protection.malwareTile.title")
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
            hero
                .frame(maxWidth: .infinity, alignment: .center)
            currentFileLabel
            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Spacer()
                controls
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaderTileGlass()
    }

    private var hero: some View {
        Image(systemName: "allergens")
            .font(.system(size: 84, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(accent)
            .shadow(color: accent.opacity(0.55), radius: 26)
            .symbolEffect(.pulse, options: .repeating, isActive: malware.isScanningPhase)
            .accessibilityHidden(true)
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

    @ViewBuilder
    private var controls: some View {
        switch malware.phase {
        case .checkingClamAV, .updatingDatabase, .scanning:
            Button(String(localized: "Stop", comment: "Stops the in-progress malware scan."),
                   action: onStop)
                .buttonStyle(.vaderGlass)
                .accessibilityIdentifier("protection.malwareTile.stop")
        case .results:
            Button(String(localized: "Review", comment: "Opens the detected-threats list."),
                   action: onReview)
                .buttonStyle(.vaderGlass)
                .accessibilityIdentifier("protection.malwareTile.review")
            Button(String(localized: "Remove", comment: "Removes all detected threats."),
                   action: onRemove)
                .buttonStyle(.vaderWhite)
                .accessibilityIdentifier("protection.malwareTile.remove")
        case .idle, .failed:
            Button(String(localized: "Scan Again", comment: "Restarts the malware scan."),
                   action: onScanAgain)
                .buttonStyle(.vaderGlass)
                .accessibilityIdentifier("protection.malwareTile.scanAgain")
        case .clean, .removing, .done, .needsInstall:
            EmptyView()
        }
    }

    private var title: String {
        switch malware.phase {
        case .checkingClamAV, .updatingDatabase, .scanning:
            return String(localized: "Looking for Threats…", comment: "Malware tile title while scanning.")
        case .clean:
            return String(localized: "No Threats Found", comment: "Malware tile title when the scan is clean.")
        case .results(let threats):
            return String(localized: "\(threats.count) Threats Found", comment: "Malware tile title when threats are found.")
        case .removing:
            return String(localized: "Removing Threats…", comment: "Malware tile title while removing threats.")
        case .done(let count):
            return String(localized: "\(count) Threats Removed", comment: "Malware tile title after removal.")
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
            return String(localized: "Your Mac is clean — no malware detected.",
                          comment: "Malware tile subtitle when clean.")
        case .results:
            return String(localized: "Review the detected threats and remove them to stay protected.",
                          comment: "Malware tile subtitle when threats are found.")
        case .removing:
            return String(localized: "Deleting the infected files.",
                          comment: "Malware tile subtitle while removing.")
        case .done:
            return String(localized: "The infected files have been deleted.",
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

/// A right-column dashboard card for a privacy result group (a browser's data
/// or recent items), built to match the Applications dashboard card: title +
/// optional metric + detail top-left, an emblem top-right, and Review/Remove
/// buttons pinned to the bottom-right.
struct ProtectionPrivacyTile: View {

    let title: String
    let metric: String?
    let caption: String
    let systemImage: String
    let onReview: (() -> Void)?
    let onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let metric {
                        Text(metric)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Spacer()
                if let onReview {
                    Button(String(localized: "Review", comment: "Opens the privacy manager for this group."),
                           action: onReview)
                        .buttonStyle(.vaderGlass)
                }
                if let onRemove {
                    Button(String(localized: "Remove", comment: "Clears this privacy group."),
                           action: onRemove)
                        .buttonStyle(.vaderWhite)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .vaderTileGlass()
    }
}
