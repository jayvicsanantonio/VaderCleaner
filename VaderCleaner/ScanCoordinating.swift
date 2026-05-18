// ScanCoordinating.swift
// Coarse scan-state abstraction letting ContentView pick the generic intro + floating Scan button vs. a scannable section's own detail UI.

import Combine

/// The three coarse phases ContentView distinguishes for a scannable section.
/// Each scannable view model keeps its own richer phase enum and maps it onto
/// one of these (the mapping lands in a later step, via extensions).
enum ScanPresentation: Equatable {
    /// Show the generic SectionIntroView + floating Scan button.
    case intro
    /// The section's scan or load is in progress.
    case working
    /// Render the section's own detail UI. Results, preview, done, failed, and
    /// needs-install all collapse here — the detail view's internal switch
    /// handles the specifics.
    case results
}

/// Adopted (in a later step) by the six scannable view models so ContentView
/// can drive the unified intro → scan → detail flow without knowing each
/// model's bespoke phase enum or scan entrypoint.
///
/// Deliberately a plain `ObservableObject` protocol: no associated types and
/// no type erasure. ContentView already holds every view model as its
/// concrete type, so it reads `scanPresentation` and calls `beginScan()`
/// directly.
///
/// `@MainActor`-isolated because every conformer is a `@MainActor` view model
/// and the only consumer is SwiftUI (also main-actor). Without this the
/// main-actor witnesses can't satisfy a nonisolated requirement, which the
/// compiler flags as a potential data race.
@MainActor
protocol ScanCoordinating: ObservableObject {
    /// The coarse phase ContentView switches on.
    var scanPresentation: ScanPresentation { get }
    /// Start the section's scan or load.
    func beginScan()
}
