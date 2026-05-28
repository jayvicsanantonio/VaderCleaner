// WindowAccessor.swift
// Zero-size NSViewRepresentable that resolves the host NSWindow once the view joins the hierarchy and hands it to a callback.

import AppKit
import SwiftUI

/// Resolves the `NSWindow` hosting a SwiftUI view. SwiftUI exposes no direct
/// handle to its window, so this zero-size representable reads `view.window`
/// once the view joins the hierarchy and hands it to `onResolve`. `onResolve`
/// can be called more than once — across a window close/reopen, or on a later
/// layout pass — so callers must treat it as idempotent.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // `view.window` is nil until the view joins the hierarchy; resolve on
        // the next runloop tick, once it has a window.
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { onResolve(window) }
    }
}
