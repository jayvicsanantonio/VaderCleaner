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

/// The content for a scannable section's intro screen. The section's colour
/// identity lives in `NavigationSection.theme`; `accent` mirrors that hue so
/// the hero, feature badges, and floating Scan disc match the window backdrop.
struct SectionPresentation {
    /// SF Symbol used as the hero when no bespoke art is supplied.
    let heroSymbol: String
    /// Asset-catalog image name for designer-supplied hero art. `nil` falls
    /// back to `heroSymbol`; wired now so art can land later with no code
    /// change.
    let heroAssetName: String?
    /// Bundle resource name (without extension) for a USDZ 3D hero model.
    /// `nil` falls back to `heroAssetName` then `heroSymbol`. When non-nil,
    /// `SectionIntroView` loads the model via RealityKit's `RealityView`
    /// (SwiftUI's `Model3D` is `@available(macOS, unavailable)`) and
    /// applies the cursor-tracking parallax tilt. The convention is to use
    /// the `NavigationSection` case name verbatim, e.g. `"smartScan"`.
    let heroModelName: String?
    /// Per-section multiplier on the USDZ's auto-normalized size in the hero
    /// frame. `1.0` is the default fit (~85% of the camera frustum); values
    /// above 1.0 grow the model on screen, below 1.0 shrink it. Use this to
    /// rebalance assets whose composition includes empty space — e.g. the
    /// Smart Scan sparkles cluster, where the surrounding negative space
    /// makes the stars themselves render smaller than the trash bin even
    /// after normalization.
    let heroModelScale: Double
    /// The section's vivid hue — mirrors `NavigationSection.theme.accent` so
    /// the intro elements match the window backdrop.
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
                heroModelName: "smartScan",
                heroModelScale: 1.6,
                accent: section.theme.accent,
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
                heroModelName: "systemJunk",
                heroModelScale: 1.7,
                accent: section.theme.accent,
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
                heroModelName: "largeOldFiles",
                heroModelScale: 1.8,
                accent: section.theme.accent,
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
                heroModelName: "spaceLens",
                heroModelScale: 1.9,
                accent: section.theme.accent,
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
                heroModelName: "malwareRemoval",
                heroModelScale: 1.7,
                accent: section.theme.accent,
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
                heroModelName: "optimization",
                heroModelScale: 2.2,
                accent: section.theme.accent,
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
        case .privacy:
            return SectionPresentation(
                heroSymbol: "lock.shield",
                heroAssetName: nil,
                heroModelName: "privacy",
                heroModelScale: 1.7,
                accent: section.theme.accent,
                tagline: String(
                    localized: "Clear browsing history, cookies, and caches across your browsers.",
                    comment: "Privacy intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "clock.arrow.circlepath",
                        title: String(localized: "Browsing History", comment: "Privacy feature row.")
                    ),
                    SectionFeature(
                        symbol: "arrow.down.circle",
                        title: String(localized: "Downloads", comment: "Privacy feature row.")
                    ),
                    SectionFeature(
                        symbol: "internaldrive",
                        title: String(localized: "Cookies & Cache", comment: "Privacy feature row.")
                    ),
                    SectionFeature(
                        symbol: "doc.text",
                        title: String(localized: "Recent Items", comment: "Privacy feature row.")
                    ),
                ]
            )
        case .applications:
            // No bespoke USDZ hero ships for Applications yet, so it uses the
            // SF Symbol hero fallback (`heroModelName: nil`). The feature rows
            // preview the cards the post-scan grid surfaces.
            return SectionPresentation(
                heroSymbol: "square.grid.2x2.fill",
                heroAssetName: nil,
                heroModelName: nil,
                heroModelScale: 1.0,
                accent: section.theme.accent,
                tagline: String(
                    localized: "Review updates, unused apps, and leftovers in one place.",
                    comment: "Applications intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "arrow.triangle.2.circlepath",
                        title: String(localized: "Updates", comment: "Applications feature row.")
                    ),
                    SectionFeature(
                        symbol: "moon.zzz",
                        title: String(localized: "Unused Apps", comment: "Applications feature row.")
                    ),
                    SectionFeature(
                        symbol: "exclamationmark.triangle",
                        title: String(localized: "Unsupported Apps", comment: "Applications feature row.")
                    ),
                    SectionFeature(
                        symbol: "trash",
                        title: String(localized: "Leftovers", comment: "Applications feature row.")
                    ),
                ]
            )
        case .healthMonitor:
            return nil
        }
    }
}
