// SunburstView.swift
// SwiftUI radial-sunburst rendering for Space Lens — lays out a parent DiskNode's subtree with SunburstLayout, draws each segment as an annular sector colored by FileCategory, and routes clicks back to DiskScannerViewModel for drill-down.

import SwiftUI

/// Renders the subtree of a single `DiskNode` as a radial sunburst — the
/// alternative to `TreemapView`. The view owns no tree; it binds to whatever
/// `node` the parent hands it (typically `viewModel.currentNode`), so
/// breadcrumb navigation just changes which node is passed in.
///
/// **Rings** — `node`'s children fill the innermost ring, their children the
/// next ring out, and so on to `maxDepth`. The hollow center shows the current
/// node's total size.
///
/// **Click → drill** — tapping a directory segment calls
/// `viewModel.drillDown(into:)`, identical to the treemap. Files are inert at
/// this stage.
///
/// **Hit testing** — each segment sets `.contentShape` to its own annular
/// sector so hover and taps fire on the arc, not its (rectangular) bounding
/// box; taps in the gaps fall through to whatever sits beneath in the `ZStack`.
struct SunburstView: View {

    var viewModel: DiskScannerViewModel
    let node: DiskNode

    /// Identity of the segment currently under the pointer, or `nil` when the
    /// pointer is off every arc. Drives the hover highlight and the floating
    /// details card.
    @State private var hoveredID: DiskNode.ID?

    /// Deepest ring to draw. Past this the arcs grow too thin to read or click;
    /// the user drills in to see deeper. Matches the layout's depth cap.
    private static let maxDepth = 5
    /// Inset from the shorter edge so the outermost ring doesn't touch the
    /// view bounds.
    private static let edgePadding: CGFloat = 12
    /// Fraction of the available radius reserved for the hollow center that
    /// carries the total-size label.
    private static let innerHoleRatio: CGFloat = 0.34
    /// Hairline between adjacent segments so neighbouring arcs stay distinct
    /// within the single crimson hue family (the treemap leans on the same
    /// idea with 1pt white tile borders).
    private static let segmentStroke: CGFloat = 0.75

    var body: some View {
        // Everything that depends only on `node` is derived once here, off the
        // resize path — `GeometryReader`'s closure below re-runs every layout
        // pass, but `body` does not. The angular layout and the id→node lookup
        // survive a resize unchanged; only the depth→radius mapping, which
        // genuinely needs the bounds, runs per pass.
        let segments = SunburstLayout.segments(
            root: node,
            maxDepth: Self.maxDepth,
            id: { $0.id },
            weight: { Double($0.size) },
            children: { $0.children }
        )
        let renderedIDs = Set(segments.map(\.id))
        let nodesByID = nodeLookup(rendered: renderedIDs)

        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let maxRadius = min(geometry.size.width, geometry.size.height) / 2 - Self.edgePadding
            let hole = max(0, maxRadius) * Self.innerHoleRatio
            let ringThickness = max(0, (maxRadius - hole)) / CGFloat(Self.maxDepth)

            ZStack {
                ForEach(segments) { segment in
                    if let diskNode = nodesByID[segment.id] {
                        segmentView(
                            segment: segment,
                            diskNode: diskNode,
                            center: center,
                            hole: hole,
                            ringThickness: ringThickness
                        )
                    }
                }
                centerLabel
                    .position(center)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // A rectangular content shape so the pointer is tracked across the
            // whole canvas — including the gaps between arcs and the center
            // hole — so the card clears when the pointer leaves an arc. The
            // arcs themselves still own their taps (they sit in front), so this
            // doesn't steal drill-down clicks.
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let id = SunburstLayout.segment(
                        at: location,
                        center: center,
                        innerHole: hole,
                        ringThickness: ringThickness,
                        segments: segments
                    )
                    if hoveredID != id { hoveredID = id }
                case .ended:
                    if hoveredID != nil { hoveredID = nil }
                }
            }
            .overlay {
                hoverCard(
                    nodesByID: nodesByID,
                    segments: segments,
                    center: center,
                    hole: hole,
                    ringThickness: ringThickness,
                    bounds: geometry.size
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-lens.sunburst")
    }

    /// Details card for the hovered segment, positioned next to the segment it
    /// describes (not the cursor — anchoring to the item keeps re-renders to
    /// hover *transitions*, so the squarified/angular layout isn't recomputed
    /// on every pointer move). Clamped to stay fully on-canvas. Renders nothing
    /// when no segment is hovered.
    @ViewBuilder
    private func hoverCard(
        nodesByID: [DiskNode.ID: DiskNode],
        segments: [SunburstLayout.Segment<DiskNode.ID>],
        center: CGPoint,
        hole: CGFloat,
        ringThickness: CGFloat,
        bounds: CGSize
    ) -> some View {
        if let hoveredID,
           let diskNode = nodesByID[hoveredID],
           let segment = segments.first(where: { $0.id == hoveredID }) {
            let midAngle = (segment.startAngle + segment.endAngle) / 2
            let midRadius = hole + (CGFloat(segment.depth) - 0.5) * ringThickness
            let anchor = CGPoint(
                x: center.x + CGFloat(cos(midAngle)) * midRadius,
                y: center.y + CGFloat(sin(midAngle)) * midRadius
            )
            SpaceLensHoverCard(
                name: diskNode.name,
                formattedSize: diskNode.formattedSize,
                fraction: node.size > 0 ? Double(diskNode.size) / Double(node.size) : 0,
                path: diskNode.url.path
            )
            .frame(width: SpaceLensHoverCard.preferredWidth)
            .fixedSize(horizontal: false, vertical: true)
            .position(SpaceLensHoverCard.clampedCenter(anchor: anchor, in: bounds))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Segment rendering

    @ViewBuilder
    private func segmentView(
        segment: SunburstLayout.Segment<DiskNode.ID>,
        diskNode: DiskNode,
        center: CGPoint,
        hole: CGFloat,
        ringThickness: CGFloat
    ) -> some View {
        let innerRadius = hole + CGFloat(segment.depth - 1) * ringThickness
        let outerRadius = hole + CGFloat(segment.depth) * ringThickness
        let sector = AnnularSector(
            center: center,
            innerRadius: innerRadius,
            outerRadius: outerRadius,
            startAngle: .radians(segment.startAngle),
            endAngle: .radians(segment.endAngle)
        )
        let category = FileCategory.from(node: diskNode)
        let isHovered = hoveredID == segment.id
        let fillOpacity = isHovered
            ? min(1.0, opacity(for: diskNode, depth: segment.depth) + 0.25)
            : opacity(for: diskNode, depth: segment.depth)

        sector
            .fill(category.color.opacity(fillOpacity))
            .overlay(
                sector.stroke(
                    isHovered ? Color.white.opacity(0.9) : Color.black.opacity(0.25),
                    lineWidth: isHovered ? Self.segmentStroke + 1 : Self.segmentStroke
                )
            )
            .contentShape(sector)
            .onTapGesture { viewModel.drillDown(into: diskNode) }
            .help("\(diskNode.url.path)\n\(diskNode.formattedSize)")
            .accessibilityIdentifier("space-lens.arc.\(diskNode.url.lastPathComponent)")
            .accessibilityLabel("\(diskNode.name), \(diskNode.formattedSize)")
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Text(node.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(node.formattedSize)
                .font(.callout.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.primary)
        .padding(8)
        .accessibilityIdentifier("space-lens.sunburst.total")
    }

    // MARK: - Helpers

    /// Fade arcs as they move outward so depth reads at a glance within the
    /// single crimson hue family, and lighten files slightly over directories
    /// (the treemap makes the same directory/file distinction).
    private func opacity(for node: DiskNode, depth: Int) -> Double {
        let base = node.isDirectory ? 0.8 : 0.95
        let faded = base - Double(depth - 1) * 0.1
        return min(1.0, max(0.4, faded))
    }

    /// Map the rendered segments back to their nodes so a laid-out segment can
    /// recover its `DiskNode` for color, tooltip, and drill-down.
    ///
    /// Driven by the `rendered` id set (`SunburstLayout`'s own output), so it
    /// stays consistent with the layout's pruning no matter how that pruning
    /// evolves, and only ever allocates entries for nodes that actually draw.
    /// The walk descends only into rendered nodes — the layout never renders a
    /// child whose parent it pruned — so a directory's thousands of unrendered
    /// tiny files are skipped rather than walked and stored on every hover
    /// transition.
    private func nodeLookup(rendered: Set<DiskNode.ID>) -> [DiskNode.ID: DiskNode] {
        var map: [DiskNode.ID: DiskNode] = [:]
        func walk(_ children: [DiskNode], depth: Int) {
            guard depth <= Self.maxDepth else { return }
            for child in children where rendered.contains(child.id) {
                map[child.id] = child
                walk(child.children, depth: depth + 1)
            }
        }
        walk(node.children, depth: 1)
        return map
    }
}

/// An annular sector (a slice of a ring) between two radii and two angles.
/// Used both to draw a sunburst segment and as its `.contentShape`, so the
/// hit area matches the visible arc exactly rather than the bounding box.
private struct AnnularSector: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: endAngle,
            endAngle: startAngle,
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}
