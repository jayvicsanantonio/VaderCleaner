// AppVendor.swift
// Classifies an installed app by its bundle-ID vendor prefix so the Applications Manager can group apps under named vendor facets (Apple, Google, Microsoft, …) with an Other fallback.

import Foundation

/// A known software vendor an installed app can be grouped under in the
/// Applications Manager's "Vendors" facet. Derived from the app's reverse-DNS
/// bundle identifier; anything unrecognised falls back to `.other`.
enum AppVendor: String, CaseIterable, Hashable, Sendable {
    case apple
    case google
    case microsoft
    case adobe
    case mozilla
    case other

    /// Reverse-DNS prefixes that map onto a named vendor. Each entry is matched
    /// on a component boundary (the prefix, or the prefix followed by a `.`) so
    /// a lookalike like `com.appleseed.app` is never read as Apple.
    private static let prefixes: [(prefix: String, vendor: AppVendor)] = [
        ("com.apple", .apple),
        ("com.google", .google),
        ("com.microsoft", .microsoft),
        ("com.adobe", .adobe),
        ("org.mozilla", .mozilla),
    ]

    /// Classifies a bundle identifier. Case-insensitive; an empty or unknown id
    /// returns `.other`.
    static func of(bundleID: String) -> AppVendor {
        let lowered = bundleID.lowercased()
        for (prefix, vendor) in prefixes {
            if lowered == prefix || lowered.hasPrefix(prefix + ".") {
                return vendor
            }
        }
        return .other
    }

    /// Human-readable vendor name shown in the facet row.
    var title: String {
        switch self {
        case .apple:     return "Apple"
        case .google:    return "Google"
        case .microsoft: return "Microsoft"
        case .adobe:     return "Adobe"
        case .mozilla:   return "Mozilla"
        case .other:     return "Other"
        }
    }
}
