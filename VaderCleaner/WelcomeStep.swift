// WelcomeStep.swift
// The first-run flow's steps and the content each one shows — hero art, copy, and the section identity the whole window adopts while that step is on screen.

import SwiftUI

/// Everything one welcome step renders. The colour identity is borrowed from a
/// real `NavigationSection` rather than invented here, so the tour is a genuine
/// preview of the app the user is about to land in: the window wears the same
/// gradient on the Cleanup step that it wears in Cleanup.
struct WelcomeStepContent: Equatable {
    /// The step's headline.
    let title: String
    /// One or two lines under the headline.
    let tagline: String
    /// Asset-catalog name for the step's hero art, or `nil` to render
    /// `heroSymbol` instead.
    let heroAssetName: String?
    /// SF Symbol hero, used when there is no asset (the permission and
    /// finish steps) and as the fallback if an asset ever goes missing.
    let heroSymbol: String
    /// The capabilities this step introduces. Empty on the non-tour steps,
    /// which carry their own bespoke content instead.
    let features: [SectionFeature]
    /// The section identity the window adopts for this step.
    let theme: SectionTheme
}

/// The steps of the first-run experience, in presentation order: a greeting,
/// a three-stop tour of what the app does, the one permission it needs, and a
/// hand-off into the first Smart Scan.
enum WelcomeStep: Int, CaseIterable, Identifiable, Hashable {
    case welcome
    case clean
    case protect
    case tune
    case access
    case ready

    var id: Int { rawValue }

    static var first: WelcomeStep { .welcome }
    static var last: WelcomeStep { allCases[allCases.count - 1] }

    /// The next step, or `nil` at the end of the flow.
    var next: WelcomeStep? { WelcomeStep(rawValue: rawValue + 1) }

    /// The previous step, or `nil` at the start of the flow.
    var previous: WelcomeStep? { WelcomeStep(rawValue: rawValue - 1) }

    /// Whether this is one of the three capability stops — the part of the
    /// flow a returning-feeling user can skip past.
    var isTour: Bool {
        switch self {
        case .clean, .protect, .tune:  return true
        case .welcome, .access, .ready: return false
        }
    }

    /// How far through the flow this step sits, 0…1. Drives the progress rail.
    var progress: Double {
        let lastIndex = Double(WelcomeStep.allCases.count - 1)
        guard lastIndex > 0 else { return 1 }
        return Double(rawValue) / lastIndex
    }

    /// Stable automation identifier for the step's container. Derived from the
    /// case name, not the localized title, so it is identical in every locale.
    var accessibilityIdentifier: String {
        "welcome.step.\(String(describing: self))"
    }

    /// What this step renders.
    var content: WelcomeStepContent {
        switch self {
        case .welcome:
            return WelcomeStepContent(
                title: String(
                    localized: "Welcome to VaderCleaner",
                    comment: "First-run flow: greeting headline."
                ),
                tagline: String(
                    localized: """
                    A cleaner, a bodyguard, and a mechanic for your Mac — \
                    in one place. Here's what the next minute buys you.
                    """,
                    comment: "First-run flow: greeting tagline."
                ),
                heroAssetName: "smartScan",
                heroSymbol: "sparkles",
                features: [],
                theme: NavigationSection.smartScan.theme
            )
        case .clean:
            return WelcomeStepContent(
                title: String(
                    localized: "Reclaim your space",
                    comment: "First-run flow: cleaning tour headline."
                ),
                tagline: String(
                    localized: """
                    Caches, logs, forgotten downloads, duplicate photos — \
                    VaderCleaner finds them, shows its work, and moves your \
                    files to the Trash so nothing is ever gone for good.
                    """,
                    comment: "First-run flow: cleaning tour tagline."
                ),
                heroAssetName: "systemJunk",
                heroSymbol: "trash",
                features: [
                    SectionFeature(
                        symbol: NavigationSection.systemJunk.icon,
                        title: NavigationSection.systemJunk.title
                    ),
                    SectionFeature(
                        symbol: NavigationSection.largeOldFiles.icon,
                        title: NavigationSection.largeOldFiles.title
                    ),
                    SectionFeature(
                        symbol: NavigationSection.spaceLens.icon,
                        title: NavigationSection.spaceLens.title
                    ),
                ],
                theme: NavigationSection.systemJunk.theme
            )
        case .protect:
            return WelcomeStepContent(
                title: String(
                    localized: "Keep the bad stuff out",
                    comment: "First-run flow: protection tour headline."
                ),
                tagline: String(
                    localized: """
                    A bundled malware scanner, a look at what your browsers \
                    remember about you, and a plain-language read on which \
                    apps hold which permissions.
                    """,
                    comment: "First-run flow: protection tour tagline."
                ),
                heroAssetName: "malwareRemoval",
                heroSymbol: "shield.lefthalf.filled",
                features: [
                    SectionFeature(
                        symbol: "allergens",
                        title: String(localized: "Malware Removal", comment: "First-run flow: protection capability.")
                    ),
                    SectionFeature(
                        symbol: "checkmark.shield.fill",
                        title: String(localized: "Privacy Check", comment: "First-run flow: protection capability.")
                    ),
                    SectionFeature(
                        symbol: "lock.fill",
                        title: String(
                            localized: "Application Permissions",
                            comment: "First-run flow: protection capability."
                        )
                    ),
                ],
                theme: NavigationSection.malwareRemoval.theme
            )
        case .tune:
            return WelcomeStepContent(
                title: String(
                    localized: "Keep it running fast",
                    comment: "First-run flow: performance tour headline."
                ),
                tagline: String(
                    localized: """
                    Trim what launches at login, uninstall apps completely, \
                    and watch memory, storage, and temperature live from the \
                    menu bar.
                    """,
                    comment: "First-run flow: performance tour tagline."
                ),
                heroAssetName: "performance",
                heroSymbol: "gauge.with.needle",
                features: [
                    SectionFeature(
                        symbol: NavigationSection.performance.icon,
                        title: NavigationSection.performance.title
                    ),
                    SectionFeature(
                        symbol: NavigationSection.applications.icon,
                        title: NavigationSection.applications.title
                    ),
                    SectionFeature(
                        symbol: NavigationSection.healthMonitor.icon,
                        title: NavigationSection.healthMonitor.title
                    ),
                ],
                theme: NavigationSection.performance.theme
            )
        case .access:
            return WelcomeStepContent(
                title: String(
                    localized: "One permission to grant",
                    comment: "First-run flow: Full Disk Access headline."
                ),
                tagline: String(
                    localized: """
                    macOS keeps caches, Mail attachments, and browser data \
                    behind Full Disk Access. Without it, scans come back \
                    empty — VaderCleaner never sends any of it anywhere.
                    """,
                    comment: "First-run flow: Full Disk Access tagline."
                ),
                heroAssetName: nil,
                heroSymbol: "lock.shield",
                features: [],
                theme: NavigationSection.smartScan.theme
            )
        case .ready:
            return WelcomeStepContent(
                title: String(
                    localized: "You're all set",
                    comment: "First-run flow: finish headline."
                ),
                tagline: String(
                    localized: """
                    Smart Scan checks the essentials in one pass and shows \
                    you every finding before anything is touched. It's the \
                    best place to start.
                    """,
                    comment: "First-run flow: finish tagline."
                ),
                heroAssetName: nil,
                heroSymbol: "checkmark.seal.fill",
                features: [],
                theme: NavigationSection.smartScan.theme
            )
        }
    }
}
