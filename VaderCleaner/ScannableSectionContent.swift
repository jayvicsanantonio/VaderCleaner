// ScannableSectionContent.swift
// Wrapper that crossfades a scannable section between its unified intro view and its own detail view, gated by the coordinator's scanPresentation.

import SwiftUI

/// Gates a scannable section between the unified `SectionIntroView` and its
/// own detail view. The coordinator is held as a plain stored property — every
/// conformer of `ScanCoordinating` is `@Observable`, so SwiftUI's view tree
/// picks up the `scanPresentation` reads in `phaseTransitionID` and re-renders
/// when the value changes. The detail closure is not evaluated while at
/// `.intro`, so the section's auto-load `.task`/`.onAppear` stays gated behind
/// Scan rather than firing under the intro.
struct ScannableSectionContent<Coordinator: ScanCoordinating, Detail: View>: View {
    let coordinator: Coordinator
    let section: NavigationSection
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        // A plain ZStack so the body's root carries no `.transition` of its
        // own. The intro↔scan crossfade lives one level in, on `content`;
        // keeping it off the root lets the outer section-navigation slide
        // (applied to this view by `ContentView`) act on a clean container
        // instead of colliding with this wrapper's own transition.
        ZStack {
            content
                // Reuse SmartScanView's phase-transition pattern so the
                // intro → scan swap crossfades instead of hard-cutting.
                .id(phaseTransitionID)
                .transition(.opacity)
                .animation(.smooth(duration: 0.35), value: phaseTransitionID)
        }
    }

    /// Binary token: only the intro ↔ detail boundary crossfades. It is
    /// deliberately *not* the full three-state `ScanPresentation` — `.working`
    /// and `.results` both render `detail()`, so distinguishing them here
    /// would change the view identity on the working → results boundary and
    /// rebuild the live detail view mid-scan (re-running its `.task`/`onAppear`
    /// and dropping in-progress state). The detail view owns its own
    /// working → results transition; `SmartScanView` already crossfades its
    /// internal phases with this same pattern.
    private var phaseTransitionID: String {
        coordinator.scanPresentation == .intro ? "intro" : "detail"
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.scanPresentation == .intro,
           let presentation = SectionPresentation.for(section) {
            SectionIntroView(presentation: presentation, section: section)
        } else {
            // `.working`/`.results`, or the defensive case of a scannable
            // section with no presentation metadata: the section's own
            // detail view is the source of truth for every non-intro phase.
            detail()
        }
    }
}
