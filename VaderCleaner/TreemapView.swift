// TreemapView.swift
// SwiftUI treemap rendering for Space Lens — lays out a parent DiskNode's children with TreemapLayout, colors each tile by FileCategory, and routes clicks back to DiskScannerViewModel for drill-down.

import SwiftUI

/// Renders the children of a single `DiskNode` as a squarified treemap.
/// The view does not own a tree — it binds to whatever `node` the parent
/// hands it (typically `viewModel.currentNode`), so navigation up and down
/// the breadcrumb stack just changes which node is passed in.
///
/// **Click → drill** — tapping a directory tile calls
/// `viewModel.drillDown(into:)`. Files are not interactive at this stage;
/// future "Show in Finder" / "Move to Trash" actions will land alongside
/// the App Uninstaller polish (Prompt 27).
///
/// **Tooltip** — hover surfaces the full path and formatted size via
/// `.help(...)`, the SwiftUI idiom for native macOS tooltips.
///
/// **Tile thresholds** — tiles below ~20 pt on the shorter side hide their
/// label (the text would overflow into a neighbour). Tiles below ~4 pt
/// in either dimension are skipped entirely; they're just visual noise at
/// that scale and the user can drill in to see them.
struct TreemapView: View {

    @ObservedObject var viewModel: DiskScannerViewModel
    let node: DiskNode

    /// Smallest tile dimension that still renders. Anything smaller is too
    /// thin to recognize and would just clutter the canvas.
    private static let minRenderDimension: CGFloat = 4
    /// Smallest tile dimension that still draws its name + size labels.
    /// Below this the labels overflow the tile and bleed into neighbours.
    private static let minLabelDimension: CGFloat = 60
    /// Border width between adjacent tiles. Subtle — heavier strokes turn
    /// the visualization into a grid of frames rather than a continuous
    /// area chart.
    private static let tileStroke: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let tiles = computeTiles(in: bounds)
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.node.id) { entry in
                    tileView(for: entry)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityIdentifier("space-lens.treemap")
    }

    // MARK: - Tile rendering

    /// Layout output paired back to the source node. Held as a struct so the
    /// `ForEach` body can reach both the tile rect and the `DiskNode` it
    /// came from in one keyed pass.
    private struct TileEntry {
        let node: DiskNode
        let rect: CGRect
        let category: FileCategory
    }

    private func computeTiles(in bounds: CGRect) -> [TileEntry] {
        // Filter out zero-byte children up front. A directory with a
        // mixture of zero-byte and large files would otherwise spend
        // half its strip budget on slivers that the
        // `minRenderDimension` filter would discard anyway, leaving
        // empty space inside the parent tile. Skipping them at the
        // weight stage means the surviving tiles share the full area.
        let children = node.children.filter { $0.size > 0 }
        guard !children.isEmpty else { return [] }

        let weighted = children.map { (id: $0.id, weight: Double($0.size)) }
        let layout = TreemapLayout.layout(items: weighted, in: bounds)
        let nodeByID = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })

        return layout.compactMap { tile -> TileEntry? in
            guard let child = nodeByID[tile.id] else { return nil }
            // Skip tiles that would render as a sliver. Below the
            // threshold the rectangle is just visual noise; the user can
            // drill into the parent if they need to see it.
            if tile.rect.width < Self.minRenderDimension || tile.rect.height < Self.minRenderDimension {
                return nil
            }
            return TileEntry(
                node: child,
                rect: tile.rect,
                category: FileCategory.from(node: child)
            )
        }
    }

    @ViewBuilder
    private func tileView(for entry: TileEntry) -> some View {
        let showLabel = entry.rect.width >= Self.minLabelDimension
            && entry.rect.height >= Self.minLabelDimension

        Rectangle()
            .fill(entry.category.color.opacity(entry.node.isDirectory ? 0.55 : 0.7))
            .overlay(
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: Self.tileStroke)
            )
            .overlay(
                Group {
                    if showLabel {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.node.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.white)
                            Text(entry.node.formattedSize)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(6)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .allowsHitTesting(false)
                    }
                }
            )
            .frame(width: entry.rect.width, height: entry.rect.height)
            .position(
                x: entry.rect.midX,
                y: entry.rect.midY
            )
            .help("\(entry.node.url.path)\n\(entry.node.formattedSize)")
            .onTapGesture {
                viewModel.drillDown(into: entry.node)
            }
            .accessibilityIdentifier("space-lens.tile.\(entry.node.url.lastPathComponent)")
            .accessibilityLabel("\(entry.node.name), \(entry.node.formattedSize)")
    }
}
