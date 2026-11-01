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
    let onResolve: @MainActor (NSWindow) -> Void

    /// Tracks the most recently resolved window so repeated `updateNSView`
    /// passes for the same window don't re-fire `onResolve`. Weak so a closed
    /// window can deallocate and a later reopen resolves afresh.
    @MainActor
    final class Coordinator {
        weak var lastWindow: NSWindow?

        /// Hands a newly resolved window to `onResolve` on the next main-queue
        /// turn. `updateNSView` runs inside SwiftUI's update, while Core
        /// Animation is committing, and callers use the window to add and
        /// move child windows — doing that mid-commit makes AppKit log
        /// "Invalid attempt to open a new transaction during CA commit". The
        /// window is recorded straight away so a second update pass in the
        /// same turn doesn't schedule it twice.
        func resolve(_ window: NSWindow, onResolve: @escaping @MainActor (NSWindow) -> Void) {
            guard lastWindow !== window else { return }
            lastWindow = window
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onResolve(window)
                }
            }
        }
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
                context.coordinator.resolve(window, onResolve: onResolve)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            context.coordinator.resolve(window, onResolve: onResolve)
        }
    }
}
