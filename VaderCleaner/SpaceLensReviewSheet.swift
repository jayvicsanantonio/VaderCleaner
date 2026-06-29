// SpaceLensReviewSheet.swift
// "Review files before removal" overlay — lists the selected items with their location and size, lets the user uncheck any, and moves the rest to the Trash.

import SwiftUI

/// Confirmation overlay shown before Space Lens removes anything. Lists the
/// top-level selected nodes (`SpaceLensSelection.selectedNodes`) with a
/// per-item checkbox, the item's location breadcrumb, and its size, then routes
/// the kept selection to `viewModel.removeSelected()` (move to Trash).
struct SpaceLensReviewSheet: View {

    var viewModel: DiskScannerViewModel
    let root: DiskNode
    let iconCache: AppIconCache

    @State private var isRemoving = false

    private static let accent = Color(red: 0.96, green: 0.20, blue: 0.78)

    var body: some View {
        let selected = viewModel.selection.selectedNodes()
        let totals = viewModel.selection.totals

        ZStack(alignment: .topLeading) {
            content(selected: selected, totals: totals)
            Button {
                viewModel.reviewActive = false
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .padding(8)
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityIdentifier("space-lens.review.close")
        }
        .frame(maxWidth: 760, maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
        .shadow(radius: 30, y: 12)
        .padding(40)
        .accessibilityIdentifier("space-lens.review")
    }

    private func content(selected: [DiskNode], totals: (count: Int, size: Int64)) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundStyle(Color(red: 0.62, green: 0.78, blue: 1.0))
                    .padding(.top, 8)
                Text("Review files before removal")
                    .font(.title.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(selected) { node in
                        reviewRow(node)
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 20)

            Divider().opacity(0.4)
            footer(totals: totals, hasSelection: !selected.isEmpty)
        }
    }

    private func reviewRow(_ node: DiskNode) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.selection.toggle(node)
            } label: {
                Image(systemName: "checkmark.square.fill")
                    .foregroundStyle(Self.accent)
            }
            .buttonStyle(.plain)
            Image(nsImage: iconCache.icon(for: node.url))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(locationBreadcrumb(for: node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(node.formattedSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("space-lens.review.row.\(node.name)")
    }

    private func footer(totals: (count: Int, size: Int64), hasSelection: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(SpaceLensListPanel.itemCountText(totals.count) + " selected")
                .font(.callout)
            Text("·").foregroundStyle(.tertiary)
            Text(ByteCountFormatter.string(fromByteCount: totals.size, countStyle: .binary))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                Task {
                    isRemoving = true
                    await viewModel.removeSelected()
                    isRemoving = false
                }
            } label: {
                if isRemoving {
                    ProgressView().controlSize(.small).padding(.horizontal, 12)
                } else {
                    Text("Remove").font(.callout.weight(.semibold)).padding(.horizontal, 8)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Self.accent)
            .disabled(!hasSelection || isRemoving)
            .accessibilityIdentifier("space-lens.review.remove")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// "Macintosh HD › Users" — the item's parent location, from the scan root
    /// down to (but not including) the item itself.
    private func locationBreadcrumb(for node: DiskNode) -> String {
        let rootComponents = root.url.standardizedFileURL.pathComponents
        let nodeComponents = node.url.standardizedFileURL.pathComponents
        // Parent components below the root, dropping the leading "/" and the
        // item's own last component.
        let parent = nodeComponents.dropFirst(rootComponents.count).dropLast()
        return ([root.name] + parent).joined(separator: " › ")
    }
}
