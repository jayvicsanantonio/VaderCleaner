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
    @State private var hoveredRow: AnyHashable?

    /// Uniform row metrics so every list row is the same height and gap.
    private static let rowHeight: CGFloat = 40
    private static let rowSpacing: CGFloat = 4

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
        let hovered = hoveredRow == AnyHashable(child.id)
        HStack(spacing: 10) {
            leadingControl(for: child, selected: selected)
            Image(nsImage: iconCache.icon(for: child.url))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            Button {
                if child.isDirectory { viewModel.drillDown(into: child) }
            } label: {
                Text(child.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!child.isDirectory)
            Text(child.formattedSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(hovered ? Color.white.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hoveredRow = $0 ? AnyHashable(child.id) : (hoveredRow == AnyHashable(child.id) ? nil : hoveredRow) }
        .accessibilityIdentifier("space-lens.row.\(child.name)")
    }

    /// A checkbox for a selectable item, or an "i" badge for a protected one.
    @ViewBuilder
    private func leadingControl(for child: DiskNode, selected: Bool) -> some View {
        if isProtected(child) {
            Image(systemName: "info.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help(SpaceLensProtection.category(url: child.url, isDirectory: child.isDirectory).displayName + " — protected from removal")
                .accessibilityIdentifier("space-lens.protected.\(child.name)")
        } else {
            Button {
                viewModel.selection.toggle(child)
            } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(selected ? Color(red: 0.96, green: 0.20, blue: 0.78) : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .accessibilityIdentifier("space-lens.checkbox.\(child.name)")
        }
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
