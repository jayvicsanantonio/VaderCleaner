// ScanDiscWindowFrame.swift
// Pure geometry for the floating Scan disc's child panel — where to place it relative to the main window so the disc straddles (or, in fullscreen, tucks above) the bottom edge.

import CoreGraphics

/// Computes the screen-coordinate frame of the borderless panel that hosts the
/// floating Scan disc. Kept free of AppKit so the placement maths can be
/// unit-tested without a window.
///
/// All rectangles use macOS screen coordinates: the origin is bottom-left and
/// `minY` is a window's bottom edge.
enum ScanDiscWindowFrame {

    /// How the disc sits relative to the main window's bottom edge.
    enum Placement: Equatable {
        /// The disc's center rests on the bottom edge — top half on the
        /// window, bottom half over the desktop. The standard windowed look.
        case straddleBottomEdge
        /// The whole disc sits on the window, its bottom edge `margin` points
        /// above the window's bottom edge. Used in fullscreen, where there is
        /// no desktop below the window to straddle into.
        case tuckedInside(margin: CGFloat)
    }

    /// Frame for the disc panel.
    ///
    /// - Parameters:
    ///   - parentFrame: the main window's frame, in screen coordinates.
    ///   - railWidth: width of the navigation rail; the disc centers over the
    ///     detail area (the window minus the rail), not the whole window.
    ///   - panelSize: side length of the square panel.
    ///   - discDiameter: diameter of the disc centered within the panel; only
    ///     affects `.tuckedInside`, which positions by the disc's own edge.
    ///   - placement: straddle the bottom edge, or tuck fully inside.
    static func panelFrame(
        parentFrame: CGRect,
        railWidth: CGFloat,
        panelSize: CGFloat,
        discDiameter: CGFloat,
        placement: Placement
    ) -> CGRect {
        let detailMidX = parentFrame.minX + railWidth + (parentFrame.width - railWidth) / 2
        let originX = detailMidX - panelSize / 2

        let centerY: CGFloat
        switch placement {
        case .straddleBottomEdge:
            // Panel center on the edge → disc center on the edge.
            centerY = parentFrame.minY
        case .tuckedInside(let margin):
            // Lift the panel so the disc's bottom edge clears the window edge
            // by `margin`.
            centerY = parentFrame.minY + margin + discDiameter / 2
        }
        let originY = centerY - panelSize / 2

        return CGRect(x: originX, y: originY, width: panelSize, height: panelSize)
    }
}
