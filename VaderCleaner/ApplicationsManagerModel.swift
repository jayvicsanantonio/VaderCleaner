// ApplicationsManagerModel.swift
// Pure facet, filter, and sort helpers behind the Applications Manager's Uninstaller pane — turns the installed-app list plus measured sizes/dates into the middle-column facet counts and the filtered, sorted right-hand list.

import Foundation

/// The ordering options offered by the Applications Manager's "Sort by:" menu.
/// A dedicated enum (rather than the shared `ManagerSort`) because this surface
/// also sorts by an app's last-opened date.
enum AppManagerSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case lastOpened
    case size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name:
            return String(localized: "Name", comment: "Applications Manager sort option ordering alphabetically.")
        case .lastOpened:
            return String(localized: "Last Opened", comment: "Applications Manager sort option ordering by most-recently-opened.")
        case .size:
            return String(localized: "Size", comment: "Applications Manager sort option ordering by size, largest first.")
        }
    }
}

/// A selectable facet in the Uninstaller pane's middle column. Mirrors the
/// reference layout: the top group (All / Unused / Suspicious / Selected), then
/// a store group, then a per-vendor group.
enum AppManagerFacet: Hashable, Sendable {
    case all
    case unused
    /// Parity placeholder — no detector is wired, so this filters to nothing.
    case suspicious
    case selected
    case store(isAppStore: Bool)
    case vendor(AppVendor)
}

/// Stateless derivations over the installed-app list. Kept separate from the
/// view so the facet counts, filtering, and ordering are unit-testable without
/// SwiftUI — the same split as `MyClutterManagerModel`.
enum ApplicationsManagerModel {

    /// Count of App Store vs. non-App-Store apps, off `AppInfo.isAppStore`.
    static func storeCounts(apps: [AppInfo]) -> (appStore: Int, other: Int) {
        var appStore = 0
        for app in apps where app.isAppStore { appStore += 1 }
        return (appStore, apps.count - appStore)
    }

    /// The vendors actually present, each with its app count, ordered by count
    /// descending (ties broken by vendor title) so the busiest vendor leads.
    static func vendorCounts(apps: [AppInfo]) -> [(vendor: AppVendor, count: Int)] {
        var counts: [AppVendor: Int] = [:]
        for app in apps {
            counts[AppVendor.of(bundleID: app.bundleID), default: 0] += 1
        }
        return counts
            .map { (vendor: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.vendor.title < $1.vendor.title
            }
    }

    /// Applies the active facet and the search query to the app list. Search is
    /// a case-insensitive substring match on the name or bundle ID.
    static func filter(
        _ apps: [AppInfo],
        facet: AppManagerFacet,
        search: String,
        unusedIDs: Set<AppInfo.ID>,
        selectedIDs: Set<AppInfo.ID>
    ) -> [AppInfo] {
        let faceted = apps.filter { app in
            switch facet {
            case .all:                      return true
            case .unused:                   return unusedIDs.contains(app.id)
            case .suspicious:               return false
            case .selected:                 return selectedIDs.contains(app.id)
            case .store(let isAppStore):    return app.isAppStore == isAppStore
            case .vendor(let vendor):       return AppVendor.of(bundleID: app.bundleID) == vendor
            }
        }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return faceted }
        return faceted.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Orders the apps for display. Size and last-opened are descending (largest
    /// / most-recent first); apps missing the measured value sink to the end so
    /// a half-built metrics cache never floats unmeasured rows to the top.
    static func sort(
        _ apps: [AppInfo],
        by sort: AppManagerSort,
        sizes: [AppInfo.ID: Int64],
        dates: [AppInfo.ID: Date]
    ) -> [AppInfo] {
        switch sort {
        case .name:
            return apps.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .size:
            return apps.sorted { (sizes[$0.id] ?? -1) > (sizes[$1.id] ?? -1) }
        case .lastOpened:
            let floor = Date.distantPast
            return apps.sorted { (dates[$0.id] ?? floor) > (dates[$1.id] ?? floor) }
        }
    }
}
