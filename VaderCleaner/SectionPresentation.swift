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
    /// Hero heading shown on the intro screen when it should differ from the
    /// sidebar's `NavigationSection.title`. `nil` falls back to the section
    /// title — most sections share one name in both places; Cleanup is the
    /// exception (sidebar "Cleanup", hero "Junk Cleanup").
    let heroTitle: String?
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
                heroAssetName: "smartScan",
                heroModelName: nil,
                heroModelScale: 1.7,
                accent: section.theme.accent,
                heroTitle: nil,
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
                        symbol: NavigationSection.performance.icon,
                        title: NavigationSection.performance.title
                    ),
                ]
            )
        case .systemJunk:
            return SectionPresentation(
                heroSymbol: "trash",
                heroAssetName: "systemJunk",
                heroModelName: nil,
                heroModelScale: 1.7,
                accent: section.theme.accent,
                heroTitle: String(
                    localized: "Junk Cleanup",
                    comment: "Cleanup intro hero heading (the sidebar label is the shorter \"Cleanup\")."
                ),
                tagline: String(
                    localized: "Clean your system to achieve maximum performance and reclaim more free space.",
                    comment: "Cleanup intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "archivebox",
                        title: String(localized: "System Junk", comment: "Cleanup feature row.")
                    ),
                    SectionFeature(
                        symbol: "envelope",
                        title: String(localized: "Mail Attachments", comment: "Cleanup feature row.")
                    ),
                    SectionFeature(
                        symbol: "trash",
                        title: String(localized: "Trash Bins", comment: "Cleanup feature row.")
                    ),
                ]
            )
        case .largeOldFiles:
            return SectionPresentation(
                heroSymbol: "doc.text.magnifyingglass",
                heroAssetName: "largeOldFiles",
                heroModelName: nil,
                heroModelScale: 1.7,
                accent: section.theme.accent,
                heroTitle: nil,
                tagline: String(
                    localized: "Sort through your files and reduce the mess in just a few clicks.",
                    comment: "My Clutter intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "doc.on.doc",
                        title: String(localized: "Large Files", comment: "My Clutter feature row.")
                    ),
                    SectionFeature(
                        symbol: "doc.on.doc.fill",
                        title: String(localized: "Duplicates", comment: "My Clutter feature row.")
                    ),
                    SectionFeature(
                        symbol: "photo.on.rectangle.angled",
                        title: String(localized: "Similar Images", comment: "My Clutter feature row.")
                    ),
                    SectionFeature(
                        symbol: "arrow.down.circle",
                        title: String(localized: "Downloads", comment: "My Clutter feature row.")
                    ),
                ]
            )
        case .spaceLens:
            return SectionPresentation(
                heroSymbol: "square.split.2x2",
                heroAssetName: "spaceLens",
                heroModelName: nil,
                heroModelScale: 1.7,
                accent: section.theme.accent,
                heroTitle: nil,
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
                heroAssetName: "malwareRemoval",
                heroModelName: nil,
                heroModelScale: 1.7,
                accent: section.theme.accent,
                heroTitle: nil,
                tagline: String(
                    localized: "Check your Mac for all kind of threats and vulnerabilities.",
                    comment: "Protection intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "allergens",
                        title: String(localized: "Malware Removal", comment: "Protection feature row.")
                    ),
                    SectionFeature(
                        symbol: "checkmark.shield.fill",
                        title: String(localized: "Privacy Check", comment: "Protection feature row.")
                    ),
                    SectionFeature(
                        symbol: "lock.fill",
                        title: String(localized: "Application Permissions", comment: "Protection feature row.")
                    ),
                ]
            )
        case .performance:
            return SectionPresentation(
                heroSymbol: "gauge.with.needle",
                heroAssetName: "performance",
                heroModelName: nil,
                heroModelScale: 1.7,
                accent: section.theme.accent,
                heroTitle: nil,
                tagline: String(
                    localized: "Keep your Mac in top shape with recommended maintenance.",
                    comment: "Performance intro tagline."
                ),
                features: [
                    SectionFeature(
                        symbol: "power",
                        title: String(localized: "Login Items", comment: "Performance feature row.")
                    ),
                    SectionFeature(
                        symbol: "gearshape",
                        title: String(localized: "Launch Agents", comment: "Performance feature row.")
                    ),
                    SectionFeature(
                        symbol: "memorychip",
                        title: String(localized: "Free Up RAM", comment: "Performance feature row.")
                    ),
                    SectionFeature(
                        symbol: "wrench.and.screwdriver",
                        title: String(localized: "Maintenance Scripts", comment: "Performance feature row.")
                    ),
                ]
            )
        case .privacy:
            return SectionPresentation(
                heroSymbol: "lock.shield",
                heroAssetName: "privacy",
                heroModelName: nil,
                heroModelScale: 1.7,
                accent: section.theme.accent,
                heroTitle: nil,
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
            // Launchpad-style 2x2 app-tile grid hero; the feature rows preview
            // the cards the post-scan grid surfaces.
            return SectionPresentation(
                heroSymbol: "square.grid.2x2.fill",
                heroAssetName: "applications",
                heroModelName: nil,
                // Unused on the image hero path (only the USDZ path reads
                // heroModelScale); kept at the struct's required default.
                heroModelScale: 1.5,
                accent: section.theme.accent,
                heroTitle: nil,
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
