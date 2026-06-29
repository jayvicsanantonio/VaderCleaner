// SpaceLensListPanel.swift
// Space Lens left panel — folder header, the Select (None/All/Manually) menu, and the per-child rows with removal checkboxes, protected "i" badges, sizes, and an expandable "Other items" group.

import SwiftUI

/// The list beside the bubble chart. Mirrors the displayed children
/// (`SpaceLensChildren`): each selectable child has a removal checkbox, each
/// protected item shows an "i" badge instead, and the long tail folds into an
/// expandable "Other items" group. Row names drill into folders via the
/// view-model, keeping the list and bubbles in lockstep.
struct SpaceLensListPanel: View {

    var viewModel: DiskScannerViewModel
    let node: DiskNode
    /// Display rows for `node`, computed once by the parent so the (potentially
    /// large) child sort isn't re-run on every render.
    let items: [SpaceLensDisplayItem]
    let iconCache: AppIconCache

    @State private var selectMode: SpaceLensSelectMode = .manually
    @State private var isOtherExpanded = false
    /// The protected row whose "i" badge is hovered, so its tooltip shows.
    @State private var hoveredProtectedID: DiskNode.ID?

    /// Uniform row metrics so every list row is the same height and gap.
    private static let rowHeight: CGFloat = 40
    private static let rowSpacing: CGFloat = 4
    /// The removal accent shared with the bubbles and bottom bar.
    private static let accent = Color(red: 0.96, green: 0.20, blue: 0.78)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            selectRow(items: items)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(items) { item in
                        if item.isOther {
                            otherGroup(item)
                        } else if let child = item.node {
                            row(for: child)
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        // Draw the protected-item tooltip at the panel level (above the
        // ScrollView) so it isn't clipped by the scrolling rows.
        .overlayPreferenceValue(ProtectedTooltipKey.self) { value in
            GeometryReader { proxy in
                if let value {
                    let rect = proxy[value.anchor]
                    tooltip(text: value.text)
                        .frame(width: 230)
                        .offset(x: rect.maxX + 8, y: rect.midY - 26)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityIdentifier("space-lens.list")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: iconCache.icon(for: node.url))
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(node.formattedSize)  |  \(Self.itemCountText(node.itemCount))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Select menu

    private func selectRow(items: [SpaceLensDisplayItem]) -> some View {
        HStack(spacing: 6) {
            Text("Select:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(SpaceLensSelectMode.allCases) { mode in
                    Button(mode.displayName) { apply(mode, items: items) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(selectMode.displayName).font(.callout.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("space-lens.selectMode")
            Spacer(minLength: 0)
        }
    }

    /// Selectable real children of the current folder (skips protected items and
    /// the "Other items" aggregate).
    private func selectableChildren(_ items: [SpaceLensDisplayItem]) -> [DiskNode] {
        items.compactMap(\.node).filter { !isProtected($0) }
    }

    private func apply(_ mode: SpaceLensSelectMode, items: [SpaceLensDisplayItem]) {
        selectMode = mode
        switch mode {
        case .all:      viewModel.selection.select(selectableChildren(items))
        case .none:     viewModel.selection.deselect(items.compactMap(\.node))
        case .manually: break
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for child: DiskNode) -> some View {
        let selected = viewModel.selection.isSelected(child)
        // The shared focus highlight: lit whenever the pointer is over this row
        // or its bubble, so the row and bubble stay in lockstep.
        let highlighted = viewModel.highlightedNodeID == child.id
        HStack(spacing: 10) {
            leadingControl(for: child, selected: selected)
            Image(nsImage: iconCache.icon(for: child.url))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            Text(child.name)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(child.formattedSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(highlighted ? Color.white.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // Hovering the row drives the shared highlight; the checkbox is a
        // separate control, so a row click drills in without toggling removal.
        .onHover { hovering in
            if hovering { viewModel.highlightedNodeID = child.id }
            else if viewModel.highlightedNodeID == child.id { viewModel.highlightedNodeID = nil }
        }
        .onTapGesture {
            if child.isDirectory { viewModel.drillDown(into: child) }
        }
        .accessibilityIdentifier("space-lens.row.\(child.name)")
    }

    /// A checkbox for a selectable item, or an "i" badge for a protected one.
    @ViewBuilder
    private func leadingControl(for child: DiskNode, selected: Bool) -> some View {
        if isProtected(child) {
            protectedBadge(child)
        } else {
            Button {
                viewModel.selection.toggle(child)
            } label: {
                checkbox(isOn: selected)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .accessibilityIdentifier("space-lens.checkbox.\(child.name)")
        }
    }

    /// Pink rounded checkbox — filled with a white check when on, an outlined
    /// square when off — matching the removal accent used across Space Lens.
    private func checkbox(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isOn ? Self.accent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1.5)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0)
            )
            .frame(width: 18, height: 18)
    }

    /// The "i" badge shown instead of a checkbox for a protected item, with a
    /// hover tooltip explaining why it can't be removed.
    private func protectedBadge(_ child: DiskNode) -> some View {
        Image(systemName: "info.circle")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 22)
            .onHover { hovering in
                if hovering { hoveredProtectedID = child.id }
                else if hoveredProtectedID == child.id { hoveredProtectedID = nil }
            }
            .anchorPreference(key: ProtectedTooltipKey.self, value: .bounds) { anchor in
                hoveredProtectedID == child.id
                    ? ProtectedTooltipValue(anchor: anchor, text: Self.protectionMessage(for: child))
                    : nil
            }
            .accessibilityIdentifier("space-lens.protected.\(child.name)")
    }

    /// The dark callout bubble shown beside a protected item's "i" badge.
    private func tooltip(text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.13, blue: 0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    // MARK: - Other items

    @ViewBuilder
    private func otherGroup(_ item: SpaceLensDisplayItem) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isOtherExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOtherExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(item.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .binary))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("space-lens.otherItems")

        if isOtherExpanded {
            ForEach(item.aggregatedChildren) { child in
                row(for: child)
            }
        }
    }

    // MARK: - Helpers

    private func isProtected(_ node: DiskNode) -> Bool {
        SpaceLensProtection.isProtected(url: node.url, isDirectory: node.isDirectory)
    }

    /// Why a protected item can't be removed, shown in its "i" badge tooltip.
    static func protectionMessage(for node: DiskNode) -> String {
        switch SpaceLensProtection.category(url: node.url, isDirectory: node.isDirectory) {
        case .homeFolder:
            return String(localized: "This is your home folder and it can't be removed here.")
        case .systemFolder, .folder, .file:
            return String(localized: "This is an essential system item and it cannot be deleted.")
        }
    }

    /// "3M items" / "155 items" — abbreviates large counts the way the
    /// reference header does.
    static func itemCountText(_ count: Int) -> String {
        let number: String
        switch count {
        case 1_000_000...:
            number = String(format: "%.0fM", Double(count) / 1_000_000)
        case 10_000...:
            number = String(format: "%.0fK", Double(count) / 1_000)
        default:
            number = count.formatted(.number)
        }
        return count == 1 ? String(localized: "1 item") : String(localized: "\(number) items")
    }
}

/// The hovered protected item's badge bounds and tooltip text, hoisted to the
/// panel root so the tooltip can draw above the scrolling rows without clipping.
private struct ProtectedTooltipValue {
    let anchor: Anchor<CGRect>
    let text: String
}

private struct ProtectedTooltipKey: PreferenceKey {
    static let defaultValue: ProtectedTooltipValue? = nil
    static func reduce(value: inout ProtectedTooltipValue?, nextValue: () -> ProtectedTooltipValue?) {
        value = value ?? nextValue()
    }
}
