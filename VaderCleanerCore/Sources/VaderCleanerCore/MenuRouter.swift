// MenuRouter.swift
// App-scope router that lets the menu bar panel deep-link into a main-window section (and optionally start that section's scan).

import Foundation
import Observation

/// Bridges the menu bar scene to the main window scene. The menu can't reach
/// `ContentView`'s navigation state directly, so it records a request here and
/// opens the window; `ContentView` observes the request, navigates, and clears
/// it.
@MainActor
@Observable
public final class MenuRouter {

    /// Section the menu has asked the main window to show, or `nil` when there
    /// is no pending request. `ContentView` consumes it and resets it to `nil`.
    public var requestedSection: NavigationSection?

    /// When `true`, the requested section should begin its scan once shown.
    /// Only meaningful for scannable sections.
    public var requestStartScan = false

    /// Public so the app can own the router; the synthesized one is internal.
    public init() {}

    /// Records a deep-link request. Callers also open/activate the main window;
    /// `ContentView` applies the request when it appears or when it changes.
    public func request(_ section: NavigationSection, startScan: Bool = false) {
        requestStartScan = startScan
        requestedSection = section
    }
}
