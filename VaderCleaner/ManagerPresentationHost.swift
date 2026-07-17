// ManagerPresentationHost.swift
// Shared dashboard↔manager exchange for the section screens: the manager zooms up from the button that opened it over the receding dashboard, and after its first open the manager subtree stays mounted (hidden and inert) so Back and reopen restore the already-built panes instantly instead of rebuilding them.

import SwiftUI

/// Pure decisions behind `ManagerPresentationHost`, split out so the keep-alive
/// and motion contract is unit-testable without rendering.
enum ManagerPresentationMotion {
    /// Whether the manager subtree is in the view tree. It first mounts on
    /// open (preserving the lazy first-open cost) and then stays mounted —
    /// hidden — across Back, so its built panes, loaded rows, and scroll
    /// positions survive to the next open.
    static func mountsManager(isPresented: Bool, hasOpened: Bool) -> Bool {
        isPresented || hasOpened
    }

    /// The retained manager's scale: full size while presented, parked at the
    /// zoom transition's hidden endpoint (90%) while dismissed so hiding in
    /// place reads identically to the removal transition it replaces. Reduce
    /// Motion pins the scale and lets opacity carry the exchange.
    static func managerScale(isPresented: Bool, reduceMotion: Bool) -> CGFloat {
        (isPresented || reduceMotion) ? 1 : 0.9
    }
}

/// Hosts a section's dashboard and its manager surface in one ZStack — the
/// stable transition host every section screen previously hand-rolled — with
/// the shared manager motion. The dashboard inserts/removes with its usual
/// recede; the manager plays its anchored-zoom transition on first open, then
/// stays mounted and swaps between visible and hidden via animated modifiers
/// that mirror the same zoom, so no state is lost between opens. While hidden
/// the manager is fully inert: not clickable, not focusable (no stray
/// keyboard-shortcut captures), and absent from accessibility.
///
/// The host claims the title-bar safe area itself (never on a transitioning
/// branch: safe-area changes inside a freshly inserted transition subtree are
/// deferred until its spring fully settles, which read as the manager stuck
/// below a title-bar-height gap for a beat after opening) and hands the
/// claimed inset back to the dashboard as `dashboardTopInset` padding.
struct ManagerPresentationHost<Dashboard: View, Manager: View>: View {
    /// Whether the manager currently covers the dashboard.
    let isPresented: Bool
    /// Where the manager zoom anchors: the button that opened it (resolved by
    /// the host via `TriggerAnchor`). Also the point Back zooms it into.
    let anchor: UnitPoint
    let reduceMotion: Bool
    /// The title-bar inset this host claims, handed back to the dashboard as
    /// top padding so only the manager extends under the title bar.
    let dashboardTopInset: CGFloat
    @ViewBuilder let dashboard: () -> Dashboard
    @ViewBuilder let manager: () -> Manager

    /// Flips on the first open and stays set for this host's lifetime, keeping
    /// the manager mounted across Back. Hosts live inside their section's
    /// results phase, so a new scan unmounts the host and resets this with it.
    @State private var managerHasOpened = false

    var body: some View {
        ZStack {
            if !isPresented {
                dashboard()
                    .padding(.top, dashboardTopInset)
                    .transition(VaderMotion.dashboardTransition(reduceMotion: reduceMotion))
            }
            if ManagerPresentationMotion.mountsManager(isPresented: isPresented, hasOpened: managerHasOpened) {
                manager()
                    // Hidden in place at the zoom transition's endpoint (scale
                    // 0.9 at the anchor, transparent), so Back animates
                    // exactly like the removal transition used to.
                    .scaleEffect(
                        ManagerPresentationMotion.managerScale(isPresented: isPresented, reduceMotion: reduceMotion),
                        anchor: anchor
                    )
                    .opacity(isPresented ? 1 : 0)
                    // Inert while hidden: no clicks, no keyboard shortcuts or
                    // focus, no accessibility/UI-test presence.
                    .allowsHitTesting(isPresented)
                    .disabled(!isPresented)
                    .accessibilityHidden(!isPresented)
                    // The first open still inserts the subtree, so the zoom-in
                    // arrives through the shared transition.
                    .transition(VaderMotion.managerTransition(anchor: anchor, reduceMotion: reduceMotion))
                    // Draw over the dashboard while the two overlap mid-swap.
                    .zIndex(1)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(VaderMotion.managerZoom, value: isPresented)
        .onChange(of: isPresented) { _, presented in
            if presented { managerHasOpened = true }
        }
    }
}
