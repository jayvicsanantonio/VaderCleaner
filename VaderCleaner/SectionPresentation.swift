// SectionPresentation.swift
// Static per-section presentation metadata for the scan-centric landing screen: hero art, accent color, tagline, and descriptive sub-feature rows.

import SwiftUI

/// One descriptive row on a section's intro screen: an SF Symbol and a label.
/// Purely informational — these rows have no actions (they tell the user what
/// the upcoming scan covers, matching the reference design).
struct SectionFeature: Equatable {
    let symbol: String
    let title: String
}

/// The visual identity for a scannable section's intro screen. The window's
/// crimson `vaderShell()` is unchanged — `accent` tints only the hero,
/// sub-feature icons, and (in a later step) the floating Scan button.
struct SectionPresentation {
    /// SF Symbol used as the hero when no bespoke art is supplied.
    let heroSymbol: String
    /// Asset-catalog image name for designer-supplied hero art. `nil` falls
    /// back to `heroSymbol`; wired now so art can land later with no code
    /// change.
    let heroAssetName: String?
    /// Accent applied to intro elements only — not the window gradient.
    let accent: Color
    /// One-line description shown under the section title.
    let tagline: String
    /// The 2–4 descriptive rows summarizing what the scan covers.
    let features: [SectionFeature]

    /// Presentation for a scannable section, or `nil` for sections that keep
    /// their bespoke UI (`NavigationSection.isScannable == false`). The switch
    /// is exhaustive so a new section is a compile-time prompt.
    static func `for`(_ section: NavigationSection) -> SectionPresentation? {
        switch section {
        case .smartScan:
            // Surface the three modules Smart Scan actually orchestrates,
            // sourced from the sections themselves so the labels/icons never
            // drift from the real screens.
            return SectionPresentation(
                heroSymbol: "sparkles",
                heroAssetName: nil,
                accent: .vaderCrimson,
                tagline: String(
                    localized: "Quick maintenance that takes care of the essentials.",
                    comment: "Smart Scan intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: NavigationSection.systemJunk.icon,
                        title: NavigationSection.systemJunk.title
                    ),
                    SectionFeature(
                        symbol: NavigationSection.malwareRemoval.icon,
                        title: NavigationSection.malwareRemoval.title
                    ),
                    SectionFeature(
                        symbol: NavigationSection.optimization.icon,
                        title: NavigationSection.optimization.title
                    ),
                ]
            )
        case .systemJunk:
            return SectionPresentation(
                heroSymbol: "trash",
                heroAssetName: nil,
                accent: .vaderCrimson,
                tagline: String(
                    localized: "Clean your system to reclaim space and boost performance.",
                    comment: "System Junk intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "internaldrive",
                        title: String(localized: "System Caches", comment: "System Junk feature row.")
                    ),
                    SectionFeature(
                        symbol: "doc.text",
                        title: String(localized: "Logs", comment: "System Junk feature row.")
                    ),
                    SectionFeature(
                        symbol: "envelope",
                        title: String(localized: "Mail Attachments", comment: "System Junk feature row.")
                    ),
                    SectionFeature(
                        symbol: "trash",
                        title: String(localized: "Trash Bins", comment: "System Junk feature row.")
                    ),
                ]
            )
        case .largeOldFiles:
            return SectionPresentation(
                heroSymbol: "doc.text.magnifyingglass",
                heroAssetName: nil,
                accent: .vaderCrimson,
                tagline: String(
                    localized: "Find big and forgotten files taking up space.",
                    comment: "Large & Old Files intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "doc.on.doc",
                        title: String(localized: "Large Files", comment: "Large & Old Files feature row.")
                    ),
                    SectionFeature(
                        symbol: "clock.arrow.circlepath",
                        title: String(localized: "Old Files", comment: "Large & Old Files feature row.")
                    ),
                    SectionFeature(
                        symbol: "arrow.down.circle",
                        title: String(localized: "Downloads", comment: "Large & Old Files feature row.")
                    ),
                ]
            )
        case .spaceLens:
            return SectionPresentation(
                heroSymbol: "square.split.2x2",
                heroAssetName: nil,
                accent: .vaderCrimson,
                tagline: String(
                    localized: "See what's using your storage with an interactive map.",
                    comment: "Space Lens intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "chart.pie",
                        title: String(localized: "Disk Usage Map", comment: "Space Lens feature row.")
                    ),
                    SectionFeature(
                        symbol: "folder",
                        title: String(localized: "Drill Into Folders", comment: "Space Lens feature row.")
                    ),
                ]
            )
        case .malwareRemoval:
            return SectionPresentation(
                heroSymbol: "shield.lefthalf.filled",
                heroAssetName: nil,
                accent: .vaderCrimson,
                tagline: String(
                    localized: "Check your Mac for threats and vulnerabilities.",
                    comment: "Malware Removal intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "ladybug",
                        title: String(localized: "Malware Scan", comment: "Malware Removal feature row.")
                    ),
                    SectionFeature(
                        symbol: "cylinder",
                        title: String(localized: "Signature Database", comment: "Malware Removal feature row.")
                    ),
                    SectionFeature(
                        symbol: "xmark.shield",
                        title: String(localized: "Quarantine", comment: "Malware Removal feature row.")
                    ),
                ]
            )
        case .optimization:
            return SectionPresentation(
                heroSymbol: "gauge.with.needle",
                heroAssetName: nil,
                accent: .vaderCrimson,
                tagline: String(
                    localized: "Keep your Mac in top shape with recommended maintenance.",
                    comment: "Optimization intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "power",
                        title: String(localized: "Login Items", comment: "Optimization feature row.")
                    ),
                    SectionFeature(
                        symbol: "gearshape",
                        title: String(localized: "Launch Agents", comment: "Optimization feature row.")
                    ),
                    SectionFeature(
                        symbol: "memorychip",
                        title: String(localized: "Free Up RAM", comment: "Optimization feature row.")
                    ),
                    SectionFeature(
                        symbol: "wrench.and.screwdriver",
                        title: String(localized: "Maintenance Scripts", comment: "Optimization feature row.")
                    ),
                ]
            )
        case .privacy, .extensions, .appUninstaller, .appUpdater, .healthMonitor:
            return nil
        }
    }
}
