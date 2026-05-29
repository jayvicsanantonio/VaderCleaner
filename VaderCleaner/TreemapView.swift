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

    var viewModel: DiskScannerViewModel
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
        // Everything that depends only on `node` is derived once here, off
        // the resize path. `GeometryReader`'s closure below re-runs on every
        // layout pass (continuously while the window is dragged), but `body`
        // does not — so the child filter, the weighted-item list, the id
        // lookup, and the per-tile `formattedSize` strings survive a resize
        // unchanged instead of being rebuilt each frame. Only the squarified
        // layout, which genuinely depends on the bounds, runs per pass.
        let models = tileModels
        let weightedItems = models.map { (id: $0.id, weight: $0.weight) }
        // Defend against duplicate ids (a corrupt scan record, or an
        // unexpected id collision) rather than trapping: keep the first model
        // for a given id. `uniqueKeysWithValues:` would crash on a duplicate.
        let modelsByID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let tiles = placeTiles(weightedItems: weightedItems, modelsByID: modelsByID, in: bounds)
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { entry in
                    tileView(for: entry)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-lens.treemap")
    }

    // MARK: - Tile rendering

    /// Size-independent per-tile data, derived once from `node`. Carries the
    /// pre-formatted size string so a `ByteCountFormatter` call isn't paid per
    /// layout pass, and the resolved `category` so the file-kind classification
    /// isn't recomputed on every resize frame.
    private struct TileModel: Identifiable {
        let id: DiskNode.ID
        let node: DiskNode
        let category: FileCategory
        let formattedSize: String
        let weight: Double

        init(node: DiskNode, category: FileCategory) {
            self.id = node.id
            self.node = node
            self.category = category
            self.formattedSize = node.formattedSize
            self.weight = Double(node.size)
        }
    }

    /// A `TileModel` paired with the rectangle the layout assigned it for the
    /// current bounds. Only `rect` changes across layout passes.
    private struct PlacedTile: Identifiable {
        let model: TileModel
        let rect: CGRect

        var id: DiskNode.ID { model.id }
    }

    /// The size-independent tile models for `node`'s displayable children.
    ///
    /// Filters out zero-byte children up front. A directory with a mixture of
    /// zero-byte and large files would otherwise spend half its strip budget
    /// on slivers that the `minRenderDimension` filter would discard anyway,
    /// leaving empty space inside the parent tile. Skipping them at the weight
    /// stage means the surviving tiles share the full area.
    private var tileModels: [TileModel] {
        node.children
            .filter { $0.size > 0 }
            .map { child in
                TileModel(node: child, category: FileCategory.from(node: child))
            }
    }

    /// Runs the squarified layout for the current bounds and pairs each result
    /// rect back to its precomputed model. This is the only treemap work that
    /// genuinely depends on the geometry, so it's the only part left inside the
    /// `GeometryReader` closure.
    private func placeTiles(
        weightedItems: [(id: DiskNode.ID, weight: Double)],
        modelsByID: [DiskNode.ID: TileModel],
        in bounds: CGRect
    ) -> [PlacedTile] {
        guard !weightedItems.isEmpty else { return [] }

        let layout = TreemapLayout.layout(items: weightedItems, in: bounds)

        return layout.compactMap { tile -> PlacedTile? in
            guard let model = modelsByID[tile.id] else { return nil }
            // Skip tiles that would render as a sliver. Below the
            // threshold the rectangle is just visual noise; the user can
            // drill into the parent if they need to see it.
            if tile.rect.width < Self.minRenderDimension || tile.rect.height < Self.minRenderDimension {
                return nil
            }
            return PlacedTile(model: model, rect: tile.rect)
        }
    }

    @ViewBuilder
    private func tileView(for entry: PlacedTile) -> some View {
        let model = entry.model
        let showLabel = entry.rect.width >= Self.minLabelDimension
            && entry.rect.height >= Self.minLabelDimension

        Rectangle()
            .fill(model.category.color.opacity(model.node.isDirectory ? 0.55 : 0.7))
            .overlay(
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: Self.tileStroke)
            )
            .overlay(
                Group {
                    if showLabel {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.node.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.white)
                            Text(model.formattedSize)
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
            .help("\(model.node.url.path)\n\(model.formattedSize)")
            .onTapGesture {
                viewModel.drillDown(into: model.node)
            }
            .accessibilityIdentifier("space-lens.tile.\(model.node.url.lastPathComponent)")
            .accessibilityLabel("\(model.node.name), \(model.formattedSize)")
    }
}
