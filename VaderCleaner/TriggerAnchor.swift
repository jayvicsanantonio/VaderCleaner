// TriggerAnchor.swift
// Resolves where the manager zoom anchors: the button (or click) that opened the manager, mapped into the transition host's unit space.

import SwiftUI
import AppKit

/// Reference-type holder for a tracked frame. Views that follow their own
/// global frame for `TriggerAnchor` keep it in one of these (held in `@State`
/// so the instance survives view-struct re-creation) instead of a `CGRect`
/// `@State`: the frame changes on every animation frame while a transition
/// slides the pane, and a value-type `@State` write per frame re-renders the
/// whole subtree, while writes into the box are invisible to SwiftUI. The
/// stored rect is only ever read inside click handlers, which never need to
/// drive rendering.
final class FrameBox {
    var rect: CGRect = .zero
}

/// Maps the interaction that opens a manager to the zoom's anchor point, so
/// the manager scales up out of the control that was pressed and back into
/// it on Back. Prefers the pressed button's center (recorded by the Vader
/// button styles via `TriggerPressRegistry`), then the raw click location,
/// then the pane's center for pointer-less opens.
enum TriggerAnchor {

    /// The anchor for the open currently being handled.
    @MainActor
    static func resolve(in paneFrame: CGRect) -> UnitPoint {
        if let press = TriggerPressRegistry.shared.consumeRecentPress() {
            return unitPoint(for: CGPoint(x: press.midX, y: press.midY), in: paneFrame)
        }
        return click(in: paneFrame)
    }

    /// The current mouse event's location mapped into `paneFrame` (the
    /// transition host's frame in SwiftUI's global space). Falls back to the
    /// center when there is no usable pointer event — e.g. keyboard
    /// activation or a programmatic open.
    @MainActor
    static func click(in paneFrame: CGRect) -> UnitPoint {
        guard let event = NSApp.currentEvent,
              let contentView = event.window?.contentView else {
            return .center
        }
        // Window base coords → content-view coords, then into the top-left
        // origin SwiftUI's global space uses (NSHostingView is flipped, but
        // guard on it rather than assume).
        let inContent = contentView.convert(event.locationInWindow, from: nil)
        let point = contentView.isFlipped
            ? inContent
            : CGPoint(x: inContent.x, y: contentView.bounds.height - inContent.y)
        return unitPoint(for: point, in: paneFrame)
    }

    /// `point` mapped into `pane`'s unit space, clamped to the pane's edges.
    /// A degenerate pane (not yet laid out) yields the center instead of
    /// dividing by zero.
    static func unitPoint(for point: CGPoint, in pane: CGRect) -> UnitPoint {
        guard pane.width > 0, pane.height > 0 else { return .center }
        return UnitPoint(
            x: min(max((point.x - pane.minX) / pane.width, 0), 1),
            y: min(max((point.y - pane.minY) / pane.height, 0), 1)
        )
    }
}

/// Records the frame of the most recently pressed styled button, so a
/// manager-opening action (which runs on the same click's mouse-up) can
/// anchor the zoom on the exact button that triggered it. The Vader button
/// styles feed this on every press; consumers take the press at most once,
/// and presses older than `freshness` are discarded — a manager opened by
/// keyboard or deep link should not anchor to some long-ago click.
@MainActor
final class TriggerPressRegistry {
    static let shared = TriggerPressRegistry()
    /// How long a press stays claimable. Generous enough for a slow click
    /// (mouse-down … mouse-up), far too short to survive between unrelated
    /// interactions.
    static let freshness: TimeInterval = 10

    private var lastPress: (frame: CGRect, at: Date)?

    /// Called by the button styles on mouse-down with the button's frame in
    /// SwiftUI's global space.
    func recordPress(frame: CGRect, at date: Date = Date()) {
        lastPress = (frame, date)
    }

    /// The pressed button's frame if one was recorded within `freshness`,
    /// cleared on read so it anchors at most one open.
    func consumeRecentPress(at date: Date = Date()) -> CGRect? {
        defer { lastPress = nil }
        guard let lastPress, date.timeIntervalSince(lastPress.at) < Self.freshness else {
            return nil
        }
        return lastPress.frame
    }
}

/// Tracks its view's global frame and reports it to `TriggerPressRegistry`
/// whenever the press begins, so every styled button can anchor a manager
/// zoom with zero call-site wiring. Attached inside the Vader button styles,
/// which already know the press state.
private struct TriggerPressRecorder: ViewModifier {
    let isPressed: Bool
    /// Boxed rather than a `CGRect` `@State`: the global frame changes every
    /// animation frame while a section transition slides the pane, and a
    /// value-type write per frame would re-render every styled button for the
    /// whole slide. The rect is only read on the press edge below.
    @State private var frame = FrameBox()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { frame.rect = $0 })
            .onChange(of: isPressed) { _, pressed in
                if pressed { TriggerPressRegistry.shared.recordPress(frame: frame.rect) }
            }
    }
}

extension View {
    /// Reports this view's frame to `TriggerPressRegistry` when `isPressed`
    /// flips on; see `TriggerPressRecorder`.
    func recordsTriggerPress(isPressed: Bool) -> some View {
        modifier(TriggerPressRecorder(isPressed: isPressed))
    }
}
