// WelcomeStore.swift
// Persisted record of whether this Mac has been through the first-run welcome flow.

import Foundation
import Observation

/// A single persisted flag: has the first-run flow been completed. Kept as its
/// own store rather than a `PreferencesStore` property because it is not a
/// preference — "Restore Defaults" must not put the user back through
/// onboarding.
///
/// The flag records *"has this been shown"*, not install age, so an absent key
/// means "unseen" — including on installs that predate the flow, which get the
/// tour once on their next launch. There is no earlier signal that could tell
/// those apart after the fact, and showing it once is the better failure.
///
/// To see the flow again without editing preferences, pass the key as a launch
/// argument: UserDefaults' argument domain outranks the persisted value and
/// writes nothing back.
///
///     open -n VaderCleaner.app --args -welcome.hasCompleted NO
///
/// `WelcomeUITests` drives that override in both directions, which is how it
/// tests a first run without clearing a developer's own preferences.
///
/// The `UserDefaults` instance is injected so tests use an isolated suite, the
/// same seam every other store in the app uses.
@MainActor
@Observable
final class WelcomeStore {

    private enum Key {
        static let hasCompleted = "welcome.hasCompleted"
        static let hasSeenScanHint = "welcome.hasSeenScanHint"
        static let resumeStep = "welcome.resumeStep"
    }

    private(set) var hasCompletedWelcome: Bool

    /// Whether the user has been shown the one-time pointer at the floating
    /// Scan disc. Tracked separately from completion: someone who finished the
    /// flow by starting a scan never needs the pointer, so the two are not the
    /// same event.
    private(set) var hasSeenScanHint: Bool

    /// Where the flow was when the process last ended, or `nil` to start at
    /// the beginning.
    ///
    /// This exists because of Full Disk Access specifically: macOS applies
    /// that permission by quitting the app, so the one step that asks for it
    /// is guaranteed to destroy the process showing it. Without a resume
    /// point the user grants access, gets relaunched, and lands back at the
    /// greeting with the whole tour to walk again.
    private(set) var resumeStep: WelcomeStep?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedWelcome = defaults.bool(forKey: Key.hasCompleted)
        self.hasSeenScanHint = defaults.bool(forKey: Key.hasSeenScanHint)
        // Stored by name, not by raw value: the raw values encode presentation
        // order, so inserting a step would renumber the rest and silently
        // repoint a stored marker at a different step. A name that no longer
        // matches a case degrades to starting over rather than resuming into
        // nothing.
        if let key = defaults.string(forKey: Key.resumeStep) {
            self.resumeStep = WelcomeStep(persistenceKey: key)
        } else {
            self.resumeStep = nil
        }
    }

    /// Records that the user has reached the end of the flow — by finishing it
    /// or by stepping through to the hand-off — so it never opens again.
    func markCompleted() {
        hasCompletedWelcome = true
        defaults.set(true, forKey: Key.hasCompleted)
        // The flow is over, so the resume point is spent. Dropping it here
        // keeps `reset()` honest: forgetting the flow shouldn't leave a stale
        // step behind for the replay to land on.
        clearResumeStep()
    }

    /// Remembers the step on screen so a relaunch returns to it.
    func recordStep(_ step: WelcomeStep) {
        resumeStep = step
        defaults.set(step.persistenceKey, forKey: Key.resumeStep)
    }

    private func clearResumeStep() {
        resumeStep = nil
        defaults.removeObject(forKey: Key.resumeStep)
    }

    /// Forgets the flow, so the next launch opens on it again. Removes the key
    /// outright so a reload starts from the fresh-install state rather than
    /// from a stored `false`.
    ///
    /// Nothing in the UI calls this today — it is the deliberate way back for a
    /// future "replay the tour" affordance, and the seam the store tests use.
    /// `PreferencesStore.restoreDefaults()` must keep leaving it alone.
    /// Records that the Scan-disc pointer has been shown and dismissed, so it
    /// never returns.
    func markScanHintSeen() {
        hasSeenScanHint = true
        defaults.set(true, forKey: Key.hasSeenScanHint)
    }

    func reset() {
        hasCompletedWelcome = false
        hasSeenScanHint = false
        defaults.removeObject(forKey: Key.hasCompleted)
        defaults.removeObject(forKey: Key.hasSeenScanHint)
        clearResumeStep()
    }
}
