// UpdateCoverage.swift
// Summarises how much of the installed-app population an update check actually reached, so the Updater can report what it inspected rather than only what it found.

import Foundation

/// An app that keeps itself current through a bundled updater, paired with
/// which one. The UI names the mechanism per row, so the user can see why
/// an app was not checked instead of assuming it was overlooked.
struct SelfUpdatingApp: Identifiable, Hashable, Sendable {
    let app: AppInfo
    let updater: SelfUpdater

    var id: String { app.id }
}

/// The outcome of an update check, counted by what it could reach.
///
/// The Updater previously reported only the updates it found, which reads
/// as "everything else is current" — false whenever most installed apps
/// publish no feed we can query. These four buckets partition the
/// discovered apps exactly, so `checked` of `total` is an honest headline.
struct UpdateCoverage: Equatable, Sendable {

    /// Apps whose feed answered — an update was found or the app is current.
    let checked: Int
    /// Apps whose feed could not be reached this pass.
    let unreachable: Int
    /// Apps that ship their own updater. Reassurance, not a to-do list.
    let selfUpdating: [SelfUpdatingApp]
    /// Apps with no update mechanism we can detect. The real blind spot,
    /// and the only bucket that warrants the user's attention.
    let unmonitored: [AppInfo]

    var total: Int {
        checked + unreachable + selfUpdating.count + unmonitored.count
    }

    init(
        checked: Int = 0,
        unreachable: Int = 0,
        selfUpdating: [SelfUpdatingApp] = [],
        unmonitored: [AppInfo] = []
    ) {
        self.checked = checked
        self.unreachable = unreachable
        self.selfUpdating = selfUpdating
        self.unmonitored = unmonitored
    }

    /// Partitions probe results into the four buckets. Both lists are
    /// sorted case-insensitively by app name: the fan-out returns results
    /// in completion order, so without sorting the facet rows would
    /// reshuffle on every check.
    init(results: [UpdateProbeResult]) {
        var checked = 0
        var unreachable = 0
        var selfUpdating: [SelfUpdatingApp] = []
        var unmonitored: [AppInfo] = []

        for result in results {
            switch result.outcome {
            case .update, .noUpdate:
                checked += 1
            case .unreachable:
                unreachable += 1
            case .skipped(.selfUpdating(let updater)):
                selfUpdating.append(SelfUpdatingApp(app: result.app, updater: updater))
            case .skipped(.unmonitored):
                unmonitored.append(result.app)
            }
        }

        self.init(
            checked: checked,
            unreachable: unreachable,
            selfUpdating: selfUpdating.sorted {
                $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending
            },
            unmonitored: unmonitored.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        )
    }
}
