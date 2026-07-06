// SpaceLensBubbleView.swift
// Space Lens bubble chart — packs the current folder's children into Liquid Glass bubbles sized by disk usage, drills in on tap, reflects the removal selection, and surfaces a details card on hover.

import SwiftUI

/// Renders the children of one `DiskNode` as a packed cluster of bubbles, areas
/// proportional to byte size (`SpaceLensBubbleLayout`). Tapping a folder bubble
/// drills in via the view-model; hovering surfaces a `SpaceLensHoverCard`.
/// Selected bubbles (driven by the shared `SpaceLensSelection`) get a magenta
/// ring so the list and chart stay in sync. The "Other items" aggregate is shown
/// but not interactive — it's expanded from the list.
struct SpaceLensBubbleView: View {

    var viewModel: DiskScannerViewModel
    let node: DiskNode
    /// Display rows for `node`, computed once by the parent so the child sort
    /// isn't re-run on every hover-driven re-render.
    let items: [SpaceLensDisplayItem]
    let iconCache: AppIconCache

    @State private var hoveredID: AnyHashable?

    /// Inset so edge bubbles and their hover rings aren't clipped by the pane.
    private static let canvasInset: CGFloat = 22
    /// Smallest radius that still draws name + size labels (tiny bubbles show
    /// the icon only, so the label never crowds them).
    private static let minLabelRadius: CGFloat = 50
    /// The selection-highlight magenta shared with the list and bottom bar.
    private static let accent = Color(red: 0.96, green: 0.20, blue: 0.78)

    var body: some View {
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.canvasInset, dy: Self.canvasInset)
            let circles = SpaceLensBubbleLayout.pack(
                items: items.map { (id: $0.id, weight: Double($0.size)) },
                in: bounds
            )
            ZStack {
                ForEach(circles, id: \.id) { circle in
                    if let item = itemsByID[circle.id] {
                        bubble(item: item, circle: circle)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let id = circles.first { hit($0, location) }?.id
                    if hoveredID != id { hoveredID = id }
                    // Mirror the hover into the shared highlight so the matching
                    // list row lights up too.
                    let nodeID = id.flatMap { itemsByID[$0]?.node?.id }
                    if viewModel.highlightedNodeID != nodeID { viewModel.highlightedNodeID = nodeID }
                case .ended:
                    if hoveredID != nil { hoveredID = nil }
                    if viewModel.highlightedNodeID != nil { viewModel.highlightedNodeID = nil }
                }
            }
            .overlay { hoverCard(circles: circles, itemsByID: itemsByID, bounds: geometry.size) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-lens.bubbles")
    }

    private func hit(_ circle: PackedCircle<AnyHashable>, _ point: CGPoint) -> Bool {
        let dx = point.x - circle.center.x
        let dy = point.y - circle.center.y
        return (dx * dx + dy * dy) <= circle.radius * circle.radius
    }

    // MARK: - Bubble

    @ViewBuilder
    private func bubble(item: SpaceLensDisplayItem, circle: PackedCircle<AnyHashable>) -> some View {
        let isHovered = hoveredID == circle.id
        // Focus highlight from either the bubble or its list row.
        let isHighlighted = item.node.map { viewModel.highlightedNodeID == $0.id } ?? false
        let isSelected = item.node.map { viewModel.selection.isSelected($0) } ?? false
        let isSelectable = item.node.map { !SpaceLensProtection.isProtected(url: $0.url, isDirectory: $0.isDirectory) } ?? false
        // A checkbox appears on hover (or when already selected) for selectable
        // bubbles big enough to host it, so the user can toggle removal right on
        // the bubble — matching the reference.
        let showCheckbox = isSelectable && (isHovered || isSelected) && circle.radius >= 30
        let showLabel = circle.radius >= Self.minLabelRadius
        // Size the icon as a fraction of the bubble so there's always a generous
        // margin inside the edge — never a fixed floor that would overflow tiny
        // bubbles. Labelled bubbles leave room for the name + size beneath.
        let iconSize = showLabel
            ? min(circle.radius * 0.78, 190)
            : circle.radius * 0.92

        ZStack {
            // Real Liquid Glass in the tiles' shade. Each bubble is its own
            // glass shape, deliberately *not* grouped in a GlassEffectContainer:
            // packed circles touch, and a container would fuse the touching
            // shapes into one blob.
            Circle()
                .fill(.clear)
                .glassEffect(bubbleGlass(isSelected: isSelected, isHovered: isHighlighted), in: .circle)
                .overlay(
                    // No resting ring: the tiles carry no border, so a bubble
                    // at rest is delineated by the glass rim alone. The ring
                    // appears only for the magenta selected/highlighted states.
                    Circle().strokeBorder(
                        isSelected ? Self.accent.opacity(0.85)
                            : (isHighlighted ? Self.accent.opacity(0.9) : Color.clear),
                        lineWidth: (isSelected || isHighlighted) ? 2 : 0
                    )
                    // The glow rides the ring: the glass-filled circle beneath
                    // is a clear view, so it can't cast the selection shadow
                    // itself.
                    .shadow(color: isSelected ? Self.accent.opacity(0.5)
                                : (isHighlighted ? Self.accent.opacity(0.45) : .clear),
                            radius: isSelected ? 22 : (isHighlighted ? 16 : 0))
                )

            VStack(spacing: 6) {
                bubbleIcon(item: item, size: iconSize)
                if showLabel {
                    Text(item.name)
                        .font(.system(size: min(max(circle.radius * 0.16, 13), 26), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .binary))
                        .font(.system(size: min(max(circle.radius * 0.13, 11), 21)).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: circle.radius * 1.55)
            .allowsHitTesting(false)

            if showCheckbox, let node = item.node {
                bubbleCheckbox(node: node, isSelected: isSelected, radius: circle.radius)
                    // Sit on the upper-left near the rim, but inside the bubble's
                    // hover area so moving onto it keeps it visible.
                    .offset(x: -circle.radius * 0.52, y: -circle.radius * 0.52)
            }
        }
        .frame(width: circle.radius * 2, height: circle.radius * 2)
        .position(circle.center)
        .onTapGesture {
            if let target = item.node, target.isDirectory {
                viewModel.drillDown(into: target)
            }
        }
        .help(item.name)
        .accessibilityIdentifier("space-lens.bubble.\(item.name)")
    }

    /// The on-bubble removal checkbox — a rounded square: a frosted, empty box
    /// when hovered-but-unselected, a solid magenta box with a white check when
    /// selected. Toggles selection without drilling in.
    private func bubbleCheckbox(node: DiskNode, isSelected: Bool, radius: CGFloat) -> some View {
        let size = min(max(radius * 0.28, 24), 54)
        let corner = size * 0.3
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return Button {
            viewModel.selection.toggle(node)
        } label: {
            ZStack {
                if isSelected {
                    shape.fill(Self.accent)
                    shape.strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("space-lens.bubble.checkbox.\(node.name)")
    }

    /// Liquid Glass for a bubble. At rest it is exactly the tiles' glass
    /// (`Glass.vaderTile`) — no `interactive` treatment, which renders its own
    /// darker button-like surface — so the chart's bubbles match the app's
    /// tile color. Selected bubbles tint magenta (keeping the removal state's
    /// color, like the reference's pink glow) and hovered bubbles lift a step
    /// brighter, both with the interactive pointer response.
    private func bubbleGlass(isSelected: Bool, isHovered: Bool) -> Glass {
        if isSelected {
            return Glass.regular.tint(Self.accent.opacity(0.35)).interactive()
        }
        if isHovered {
            return Glass.regular.tint(.white.opacity(0.2)).interactive()
        }
        return .vaderTile
    }

    @ViewBuilder
    private func bubbleIcon(item: SpaceLensDisplayItem, size: CGFloat) -> some View {
        if let node = item.node {
            Image(nsImage: iconCache.icon(for: node.url))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: size * 0.8, weight: .medium))
                .foregroundStyle(Color(red: 0.7, green: 0.82, blue: 1.0))
        }
    }

    // MARK: - Hover card

    @ViewBuilder
    private func hoverCard(
        circles: [PackedCircle<AnyHashable>],
        itemsByID: [AnyHashable: SpaceLensDisplayItem],
        bounds: CGSize
    ) -> some View {
        if let hoveredID,
           let circle = circles.first(where: { $0.id == hoveredID }),
           let item = itemsByID[hoveredID] {
            let rect = CGRect(
                x: circle.center.x - circle.radius,
                y: circle.center.y - circle.radius,
                width: circle.radius * 2,
                height: circle.radius * 2
            )
            let category = item.node.map {
                SpaceLensProtection.category(url: $0.url, isDirectory: $0.isDirectory)
            }
            // Per-bubble: the "Selected:" line reflects only the hovered node's
            // own selection, so an unselected bubble shows no such line.
            let hoveredSelection = item.node.map {
                viewModel.selection.selectionTotal(for: $0)
            } ?? (count: 0, size: 0)
            SpaceLensHoverCard(
                name: item.name,
                category: category?.displayName ?? String(localized: "Group"),
                categoryIsProtected: item.node.map {
                    SpaceLensProtection.isProtected(url: $0.url, isDirectory: $0.isDirectory)
                } ?? false,
                formattedSize: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .binary),
                itemCount: item.itemCount,
                modificationDate: item.node?.modificationDate,
                selectedCount: hoveredSelection.count,
                selectedSize: hoveredSelection.size
            )
            .frame(width: SpaceLensHoverCard.preferredWidth)
            .fixedSize(horizontal: false, vertical: true)
            .position(SpaceLensHoverCard.anchor(forTile: rect, in: bounds))
            .allowsHitTesting(false)
        }
    }
}
