// SpaceLensReviewSheet.swift
// "Review files before removal" overlay — pairs the 3D Space Lens hero with the list of selected items (location + size), lets the user uncheck any, and moves the kept selection to the Trash.

import SwiftUI

/// Confirmation overlay shown before Space Lens removes anything. A two-column
/// card: the 3D Space Lens hero on the leading edge, and on the trailing edge
/// the title, the list of top-level selected nodes — each with a per-item
/// checkbox, a location breadcrumb, and its size — and the running totals with
/// the Remove action that routes the kept selection to `viewModel.removeSelected()`.
struct SpaceLensReviewSheet: View {

    var viewModel: DiskScannerViewModel
    let root: DiskNode
    let iconCache: AppIconCache

    @State private var isRemoving = false

    /// Snapshot of the items to review, captured when the overlay appears, so a
    /// row stays visible (and re-checkable) after it's unchecked rather than
    /// vanishing the moment it leaves `selection.selectedNodes()`.
    @State private var reviewNodes: [DiskNode] = []

    private static let accent = Color(red: 0.96, green: 0.20, blue: 0.78)

    var body: some View {
        let totals = viewModel.selection.totals

        ZStack(alignment: .topLeading) {
            HStack(spacing: 24) {
                hero
                content(totals: totals)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)

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
        .frame(maxWidth: 880, maxHeight: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08)))
        .shadow(radius: 30, y: 12)
        .padding(40)
        .accessibilityIdentifier("space-lens.review")
        .onAppear {
            // Capture the selection once so unchecking keeps the row on screen.
            reviewNodes = viewModel.selection.selectedNodes()
        }
    }

    // MARK: - Hero

    /// The 3D Space Lens art that anchors the leading column, matching the
    /// section's icon elsewhere in the app.
    private var hero: some View {
        Image("spaceLens")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(maxWidth: 300, maxHeight: 300)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    // MARK: - Content

    private func content(totals: (count: Int, size: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Review files before removal")
                .font(.system(size: 34, weight: .semibold))
                .padding(.bottom, 24)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(reviewNodes) { node in
                        reviewRow(node)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            footer(totals: totals, hasSelection: totals.count > 0)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func reviewRow(_ node: DiskNode) -> some View {
        let isOn = viewModel.selection.isSelected(node)
        return HStack(spacing: 14) {
            Button {
                viewModel.selection.toggle(node)
            } label: {
                checkbox(isOn: isOn)
            }
            .buttonStyle(.plain)

            Image(nsImage: iconCache.icon(for: node.url))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(locationBreadcrumb(for: node))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 12)

            Text(node.formattedSize)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .opacity(isOn ? 1 : 0.45)
        .padding(.vertical, 8)
        .accessibilityIdentifier("space-lens.review.row.\(node.name)")
    }

    /// Pink rounded checkbox — filled with a white check when on, an outlined
    /// square when off — matching the section's removal accent.
    private func checkbox(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isOn ? Self.accent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1.5)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0)
            )
            .frame(width: 22, height: 22)
    }

    private func footer(totals: (count: Int, size: Int64), hasSelection: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(Self.selectedCountText(totals.count))
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("space-lens.review.selectedCount")
            Text("|").foregroundStyle(.tertiary)
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
    }

    /// "983K Items selected" — abbreviates large counts the way the reference
    /// footer does, with singular "1 Item selected".
    static func selectedCountText(_ count: Int) -> String {
        let number: String
        switch count {
        case 1_000_000...:
            number = String(format: "%.0fM", Double(count) / 1_000_000)
        case 10_000...:
            number = String(format: "%.0fK", Double(count) / 1_000)
        default:
            number = count.formatted(.number)
        }
        return count == 1
            ? String(localized: "1 Item selected")
            : String(localized: "\(number) Items selected")
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
