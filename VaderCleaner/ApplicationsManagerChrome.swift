// ApplicationsManagerChrome.swift
// Constants and shared subviews (header, selectable row, checkbox, empty and loading states) used across the Applications Manager panes.

import SwiftUI

/// Constants and helpers shared by the Applications Manager and its pane
/// subviews. The accent is the standalone Manager magenta shared across the
/// manager screens.
enum ApplicationsManagerChrome {
    static let accent = ManagerChrome.accent

    static func byteText(_ bytes: Int64) -> String {
        formattedFileBytes(bytes)
    }
}

/// A pane's title + description block, above its facet list or item list.
struct ApplicationsManagerPaneHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
    }
}

/// A nav / facet / section row with the manager's selection pill and a quieter
/// hover fill — the magenta `ManagerChrome.accent` active/hover states every
/// manager's left and middle panes share (active fill plus a border, hover a
/// lighter fill with no border).
struct ApplicationsManagerSelectableRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? ManagerChrome.accent.opacity(0.22) : (hovered ? ManagerChrome.accent.opacity(0.08) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? ManagerChrome.accent.opacity(0.40) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A facet row in a pane's middle column: the facet's label on the left and its
/// item count on the right. The facet type itself stays with each pane — the
/// panes key off different enums and apply different side effects on selection —
/// so this owns only the row's appearance, which is identical across all of them.
struct ApplicationsManagerFacetRow: View {
    let label: String
    let count: Int
    let selected: Bool
    let select: () -> Void

    var body: some View {
        ApplicationsManagerSelectableRow(selected: selected, action: select) {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Text("\(count)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A row checkbox tinted with the manager accent when selected.
struct ApplicationsManagerCheckbox: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        ManagerRowCheckbox(isOn: selected, action: action)
    }
}

/// A quiet group header inside a facet column ("Stores", "Vendors", …).
struct ApplicationsManagerFacetSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

/// Centered icon + title + detail empty state for a pane with no items.
struct ApplicationsManagerEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.tint.opacity(0.7))
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right pane's loading spinner while the app list is still discovering.
struct ApplicationsManagerLoadingPane: View {
    var body: some View {
        VStack { Spacer(); ProgressView().controlSize(.large); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("applications.manager.loading")
    }
}
