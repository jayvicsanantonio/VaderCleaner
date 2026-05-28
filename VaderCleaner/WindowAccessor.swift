// WindowAccessor.swift
// Zero-size NSViewRepresentable that resolves the host NSWindow once the view joins the hierarchy and hands it to a callback.

import AppKit
import SwiftUI

/// Resolves the `NSWindow` hosting a SwiftUI view. SwiftUI exposes no direct
/// handle to its window, so this zero-size representable reads `view.window`
/// once the view joins the hierarchy and hands it to `onResolve`. SwiftUI calls
/// `updateNSView` on every layout pass, so the coordinator records the last
/// resolved window and only fires `onResolve` when the host window actually
/// changes — sparing callers redundant work and the "Publishing changes from
/// within view updates" trap. `onResolve` can still fire more than once across
/// a window close/reopen, so callers should remain idempotent.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    /// Tracks the most recently resolved window so repeated `updateNSView`
    /// passes for the same window don't re-fire `onResolve`. Weak so a closed
    /// window can deallocate and a later reopen resolves afresh.
    final class Coordinator {
        weak var lastWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // `view.window` is nil until the view joins the hierarchy; resolve on
        // the next runloop tick, once it has a window.
        DispatchQueue.main.async {
            if let window = view.window {
                resolve(window, coordinator: context.coordinator)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            resolve(window, coordinator: context.coordinator)
        }
    }

    private func resolve(_ window: NSWindow, coordinator: Coordinator) {
        guard coordinator.lastWindow !== window else { return }
        coordinator.lastWindow = window
        onResolve(window)
    }
}
