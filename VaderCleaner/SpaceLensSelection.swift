// SpaceLensSelection.swift
// Tracks which Space Lens nodes are marked for removal and computes deduped totals (item count + bytes) directly from the selected set — never by walking the scanned tree — so hover and selection stay instant on a multi-million-node volume.

import Foundation
import Observation

/// The "Select:" dropdown modes above the Space Lens list.
enum SpaceLensSelectMode: String, CaseIterable, Identifiable {
    case manually
    case all
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manually: return String(localized: "Manually")
        case .all:      return String(localized: "All")
        case .none:     return String(localized: "None")
        }
    }
}

/// Selection state for Space Lens removal.
///
/// **Performance:** the selected nodes are stored directly, so the running
/// "N items selected · size" totals are computed from that small set — not by
/// traversing the scanned tree. A whole-volume scan holds millions of nodes;
/// recomputing totals by walking it on every hover/click is what caused the
/// UI to stall, so nothing here ever touches the full tree.
///
/// Selecting a folder implies its whole subtree, so totals **dedupe nested
/// selections** by path: if both a folder and something inside it are selected,
/// only the folder counts. Dedup compares the (few) selected nodes against each
/// other, never the tree.
@MainActor
@Observable
final class SpaceLensSelection {

    /// Ids of selected nodes, for an O(1) `isSelected` check in row/bubble bodies.
    private(set) var selectedIDs: Set<DiskNode.ID> = []

    /// The selected nodes themselves, keyed by id, so totals and the review list
    /// read straight from here without walking the tree.
    private var selected: [DiskNode.ID: DiskNode] = [:]

    var isEmpty: Bool { selectedIDs.isEmpty }

    func isSelected(_ node: DiskNode) -> Bool {
        selectedIDs.contains(node.id)
    }

    func toggle(_ node: DiskNode) {
        if selectedIDs.contains(node.id) {
            selectedIDs.remove(node.id)
            selected[node.id] = nil
        } else {
            selectedIDs.insert(node.id)
            selected[node.id] = node
        }
    }

    /// Add every given node to the selection (callers pass already-filtered,
    /// non-protected nodes — protection lives in `SpaceLensProtection`).
    func select(_ nodes: [DiskNode]) {
        for node in nodes {
            selectedIDs.insert(node.id)
            selected[node.id] = node
        }
    }

    /// Remove every given node from the selection.
    func deselect(_ nodes: [DiskNode]) {
        for node in nodes {
            selectedIDs.remove(node.id)
            selected[node.id] = nil
        }
    }

    func clear() {
        selectedIDs.removeAll()
        selected.removeAll()
    }

    /// The top-level selected nodes — selected nodes with no selected ancestor —
    /// deduped by file path among the selected set only (no tree walk). The
    /// review sheet lists these; the totals sum over them.
    func selectedNodes() -> [DiskNode] {
        let all = Array(selected.values)
        guard all.count > 1 else { return all }
        let paths = all.map { $0.url.standardizedFileURL.path }
        return all.enumerated().filter { index, _ in
            let path = paths[index]
            // Drop this node if another selected node is a parent of it.
            return !paths.enumerated().contains { otherIndex, otherPath in
                otherIndex != index && path.hasPrefix(otherPath + "/")
            }
        }.map(\.element)
    }

    /// Deduped running totals across the current selection: the count is the
    /// number of items the removal would clear — a folder reports its contained
    /// items (`itemCount`), a file counts as one — and the size is rolled-up
    /// bytes. O(selected²), independent of the scanned tree's size.
    var totals: (count: Int, size: Int64) {
        var count = 0
        var size: Int64 = 0
        for node in selectedNodes() {
            count += node.isDirectory ? node.itemCount : 1
            size += node.size
        }
        return (count, size)
    }

    /// A single node's removal contribution *when it is selected*, else zero —
    /// the count follows the same rule as `totals` (a folder reports its
    /// contained `itemCount`, a file counts as one). Drives the hover card's
    /// per-bubble "Selected:" line, which appears only for the hovered node.
    func selectionTotal(for node: DiskNode) -> (count: Int, size: Int64) {
        guard isSelected(node) else { return (0, 0) }
        return (node.isDirectory ? node.itemCount : 1, node.size)
    }
}
