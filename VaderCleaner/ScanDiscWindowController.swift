// ScanDiscWindowController.swift
// Owns the borderless child panel that hosts the floating Scan disc, so the disc can straddle the main window's bottom edge — top half on the window, bottom half over the desktop.

import AppKit
import SwiftUI

/// Manages a borderless `NSPanel`, attached as a child of the app's main
/// window, that hosts the floating Scan disc. A child panel is the only way to
/// render the disc outside the main window's bounds: a window clips all of its
/// own content, so a plain SwiftUI overlay can never cross the bottom edge.
///
/// ContentView pushes the sidebar selection onto `section`; the panel's SwiftUI
/// root (`ScanDiscHostView`) mirrors it and reports, via `setDiscVisible(_:)`,
/// whether a disc is currently on screen so the panel is ordered in or out to
/// match.
@MainActor
@Observable
final class ScanDiscWindowController {

    /// The section whose disc the panel currently shows — driven by ContentView.
    var section: NavigationSection = .smartScan

    // The seven scannable sections' coordinators. `ScanDiscHostView` switches
    // on `section` to drive the matching one.
    @ObservationIgnored let smartScanViewModel: SmartScanViewModel
    @ObservationIgnored let systemJunkViewModel: SystemJunkViewModel
    @ObservationIgnored let largeOldFilesViewModel: LargeOldFilesViewModel
    @ObservationIgnored let spaceLensViewModel: DiskScannerViewModel
    @ObservationIgnored let optimizationViewModel: OptimizationViewModel
    @ObservationIgnored let malwareViewModel: MalwareViewModel
    @ObservationIgnored let privacyViewModel: PrivacyViewModel
    @ObservationIgnored let applicationsViewModel: ApplicationsViewModel

    /// Diameter of the disc itself — the single shared constant the disc, this
    /// panel, and the placement maths all key off.
    @ObservationIgnored private let discDiameter = FloatingScanButton.floatingDiameter
    /// Side length of the square panel. Wider than the disc so its breathing
    /// accent glow is not clipped by the panel bounds.
    @ObservationIgnored private let panelSize = FloatingScanButton.floatingDiameter + 100
    /// Gap kept below the disc panel when it is tucked fully inside
    /// (fullscreen, where there is no desktop below the window to straddle
    /// into).
    @ObservationIgnored private let fullScreenMargin: CGFloat = 36

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var parentWindow: NSWindow?
    @ObservationIgnored private var appState: AppState?
    @ObservationIgnored private var railWidth: CGFloat = 0
    @ObservationIgnored private var isFullScreen = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(
        smartScanViewModel: SmartScanViewModel,
        systemJunkViewModel: SystemJunkViewModel,
        largeOldFilesViewModel: LargeOldFilesViewModel,
        spaceLensViewModel: DiskScannerViewModel,
        optimizationViewModel: OptimizationViewModel,
        malwareViewModel: MalwareViewModel,
        privacyViewModel: PrivacyViewModel,
        applicationsViewModel: ApplicationsViewModel
    ) {
        self.smartScanViewModel = smartScanViewModel
        self.systemJunkViewModel = systemJunkViewModel
        self.largeOldFilesViewModel = largeOldFilesViewModel
        self.spaceLensViewModel = spaceLensViewModel
        self.optimizationViewModel = optimizationViewModel
        self.malwareViewModel = malwareViewModel
        self.privacyViewModel = privacyViewModel
        self.applicationsViewModel = applicationsViewModel
    }

    /// Attaches the disc panel as a child of the app's main window. Idempotent:
    /// re-attaching to the same window only re-positions, and attaching to a
    /// different window detaches the old one first — `ContentView.onAppear` can
    /// fire more than once across a window close/reopen.
    func attach(to window: NSWindow, railWidth: CGFloat, appState: AppState) {
        self.railWidth = railWidth
        self.appState = appState

        if parentWindow === window, panel != nil {
            reposition()
            return
        }
        if parentWindow != nil { detach() }

        parentWindow = window
        let panel = makePanel(appState: appState)
        self.panel = panel
        window.addChildWindow(panel, ordered: .above)
        isFullScreen = window.styleMask.contains(.fullScreen)
        installObservers(for: window)
        reposition()
    }

    /// Updates the rail width the disc centers against and re-positions the
    /// panel. ContentView calls this when the rail collapses/expands so the disc
    /// stays centered over the (now wider or narrower) detail area.
    func setRailWidth(_ width: CGFloat) {
        guard railWidth != width else { return }
        railWidth = width
        reposition()
    }

    /// Shows or hides the panel. The panel is ordered in only while a scannable
    /// section's disc should be on screen, so its transparent margin never
    /// intercepts clicks meant for the main window behind it.
    func setDiscVisible(_ visible: Bool) {
        guard let panel, let parentWindow else { return }
        if visible {
            if panel.parent == nil {
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            reposition()
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel construction

    private func makePanel(appState: AppState) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelSize, height: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A floating, non-activating accessory: clicking the disc must not
        // steal key status from the main window or dim its traffic lights.
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The disc draws its own glow in SwiftUI; a system window shadow would
        // wrap the whole transparent panel.
        panel.hasShadow = false
        // An NSHostingView in a borderless panel does not inherit the main
        // window's appearance — force the dark scheme the app runs in so
        // Liquid Glass adopts its light-on-dark treatment.
        panel.appearance = NSAppearance(named: .darkAqua)
        // Let the panel ride along when the main window enters fullscreen.
        panel.collectionBehavior = [.fullScreenAuxiliary]

        panel.contentView = NSHostingView(
            rootView: ScanDiscHostView(controller: self)
                .environment(appState)
        )
        return panel
    }

    // MARK: - Positioning

    private func reposition() {
        guard let panel, let parentWindow else { return }
        let placement: ScanDiscWindowFrame.Placement = isFullScreen
            ? .tuckedInside(margin: fullScreenMargin)
            : .straddleBottomEdge
        let frame = ScanDiscWindowFrame.panelFrame(
            parentFrame: parentWindow.frame,
            railWidth: railWidth,
            panelSize: panelSize,
            discDiameter: discDiameter,
            placement: placement,
            // Hold the disc on the visible screen even when the window is
            // dragged against the bottom edge.
            screenVisibleFrame: parentWindow.screen?.visibleFrame
        )
        panel.setFrame(frame, display: true)
    }

    // MARK: - Parent window observation

    private func installObservers(for window: NSWindow) {
        let center = NotificationCenter.default

        func observe(_ name: NSNotification.Name, _ handler: @escaping () -> Void) {
            let token = center.addObserver(
                forName: name, object: window, queue: .main
            ) { _ in
                // The `.main` queue guarantees the main thread; bridge that to
                // main-actor isolation so the controller's methods are callable.
                MainActor.assumeIsolated(handler)
            }
            observers.append(token)
        }

        // A child window moves with its parent automatically, but a resize
        // leaves it pinned to its old origin — recenter on both.
        observe(NSWindow.didResizeNotification) { [weak self] in self?.reposition() }
        observe(NSWindow.didMoveNotification) { [weak self] in self?.reposition() }
        observe(NSWindow.didEnterFullScreenNotification) { [weak self] in
            self?.isFullScreen = true
            self?.reposition()
        }
        observe(NSWindow.didExitFullScreenNotification) { [weak self] in
            self?.isFullScreen = false
            self?.reposition()
        }
        observe(NSWindow.willCloseNotification) { [weak self] in self?.detach() }
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let panel, let parentWindow, panel.parent != nil {
            parentWindow.removeChildWindow(panel)
        }
        panel?.orderOut(nil)
        panel = nil
        parentWindow = nil
    }
}
