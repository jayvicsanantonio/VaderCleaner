// CareDomainArt.swift
// Per-domain 3D artwork and accent colour shared by the scanning grid and the results tiles, so both screens speak one visual identity per care domain.

import SwiftUI

extension CareDomain {

    /// Asset-catalog name of the domain's pre-coloured 3D art — the same
    /// artwork its standalone section uses, so a tile reads instantly as
    /// that section. Browser Privacy (new, no section art) wears the glossy
    /// cookie badge.
    var artAsset: String {
        switch self {
        case .systemJunk: return "systemJunk"
        case .malware: return "malwareRemoval"
        case .performance: return "performance"
        case .applications: return "applications"
        case .myClutter: return "largeOldFiles"
        case .browserPrivacy: return "scanBadgeCookies"
        }
    }

    /// The accent behind the art's bloom and the scanning tile's traveling
    /// border — each section's own theme colour.
    var artTint: Color {
        switch self {
        case .systemJunk: return NavigationSection.systemJunk.theme.accent
        case .malware: return NavigationSection.malwareRemoval.theme.accent
        case .performance: return NavigationSection.performance.theme.accent
        case .applications: return NavigationSection.applications.theme.accent
        case .myClutter: return NavigationSection.largeOldFiles.theme.accent
        case .browserPrivacy: return .indigo
        }
    }
}
