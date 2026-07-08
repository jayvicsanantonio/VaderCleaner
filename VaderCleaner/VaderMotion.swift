// VaderMotion.swift
// Shared motion vocabulary: the springs and surface transitions that give every control press, hover fill, and manager push the same macOS Tahoe-style response.

import SwiftUI

/// The app-wide motion vocabulary. Controls answer a click with a quick
/// springy press, hover fills fade rather than snap, and full-screen
/// surfaces (a manager zooming over its dashboard) exchange with a soft
/// scale-and-fade that reads as depth — the way macOS Tahoe's Liquid Glass
/// surfaces respond. Centralised so every screen speaks with one motion
/// accent instead of per-view one-off curves.
enum VaderMotion {
    /// Quick spring for direct-manipulation feedback: button presses and
    /// checkbox flips. Snappy enough to track the pointer, with a touch of
    /// bounce on the release so controls feel elastic rather than mechanical.
    static let control: Animation = .snappy(duration: 0.22, extraBounce: 0.06)
    /// Short fade for hover fills and selection pills — pointer feedback
    /// should ease in, not blink, and carries no bounce.
    static let hover: Animation = .easeOut(duration: 0.18)
    /// Duration of the full-surface exchange spring. Shared so a caller that
    /// must wait for a surface swap to land — Smart Scan holds a sub-scan until
    /// its hero tile has arrived — stays in lockstep with the animation instead
    /// of hard-coding a matching delay that could drift out of sync.
    static let surfaceDuration: TimeInterval = 0.45
    /// Soft spring for full-surface exchanges — the sections' scan-phase
    /// swaps and the dashboard recede.
    static let surface: Animation = .smooth(duration: surfaceDuration)
    /// The manager zoom's clock: a quick snappy spring — fast enough to stay
    /// out of the way on the hundredth open, with just enough bounce to feel
    /// alive.
    static let managerZoom: Animation = .snappy(duration: 0.4)

    /// How far a pressed control shrinks: 96% reads as the Tahoe glass press
    /// dip without making the label swim.
    static let pressedScale: CGFloat = 0.96

    /// Scale a control should render at for a given press state. Reduce
    /// Motion pins the control at full size — the press still reads through
    /// each style's opacity dip.
    static func pressScale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        guard isPressed, !reduceMotion else { return 1 }
        return pressedScale
    }

    /// Transition for a manager surface: an anchored zoom in the platform
    /// idiom — the manager scales up from 90% at `anchor` (the button that
    /// triggered it, resolved via `TriggerAnchor`) while fading in, and
    /// zooms back into the same point on Back. One uniform scale, no
    /// distortion — calm enough to survive constant use, anchored enough to
    /// keep the "it came from here" read. Reduce Motion collapses it to a
    /// plain crossfade.
    static func managerTransition(anchor: UnitPoint = .center, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9, anchor: anchor).combined(with: .opacity)
    }

    /// Transition for the dashboard beneath a manager: a subtler recede to
    /// 97% and fade while the manager covers it, returning forward when the
    /// manager closes. Reduce Motion collapses it to a plain crossfade.
    static func dashboardTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity)
    }
}

