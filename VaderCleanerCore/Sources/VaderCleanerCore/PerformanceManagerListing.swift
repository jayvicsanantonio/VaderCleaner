// PerformanceManagerListing.swift
// What the Performance Manager lists for a search, and which selected rows a bulk action may reach — only ever the ones on screen.

import Foundation

/// The Performance Manager's list rules, kept apart from its view so they can be
/// tested without one. The rule that matters is that search never widens what a
/// bulk action touches: a destructive Remove acts on what the user can see, not
/// on rows a filter is hiding.
public enum PerformanceManagerListing {

    /// `items` whose title or subtitle contain `query`, ordered by title.
    public static func items(_ items: [ManagerItem], matching query: String) -> [ManagerItem] {
        items
            .filter { item in
                query.isEmpty
                    || item.title.localizedCaseInsensitiveContains(query)
                    || item.subtitle?.localizedCaseInsensitiveContains(query) == true
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// `tasks` whose title or summary contain `query`, ordered by title.
    public static func tasks(_ tasks: [MaintenanceTask], matching query: String) -> [MaintenanceTask] {
        tasks
            .filter { task in
                query.isEmpty
                    || task.title.localizedCaseInsensitiveContains(query)
                    || task.summary.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The part of `selection` a bulk action may act on: the visible rows.
    public static func actionableSelection(_ selection: Set<String>, visibleIDs: [String]) -> Set<String> {
        selection.intersection(visibleIDs)
    }

    /// `selection` with every visible row added.
    public static func selectingAll(in selection: Set<String>, visibleIDs: [String]) -> Set<String> {
        selection.union(visibleIDs)
    }

    /// `selection` with every visible row removed. A row hidden by the search
    /// keeps its checkbox, so clearing the search doesn't lose it.
    public static func deselectingAll(in selection: Set<String>, visibleIDs: [String]) -> Set<String> {
        selection.subtracting(visibleIDs)
    }

    /// The names a confirmation shows, one per line, capped at `limit` so a long
    /// selection can't push the alert's buttons off screen.
    public static func confirmationList(names: [String], limit: Int) -> String {
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var lines = Array(sorted.prefix(limit))
        if sorted.count > limit {
            let format = String(
                localized: "and %lld more",
                bundle: .module,
                comment: "Last line of a confirmation's item list; %lld is how many items aren't named."
            )
            lines.append(String.localizedStringWithFormat(format, sorted.count - limit))
        }
        return lines.joined(separator: "\n")
    }
}
