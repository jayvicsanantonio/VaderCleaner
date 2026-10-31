// ApplicationsManagerChrome.swift
// Constants and shared subviews (header, selectable row, checkbox, empty and loading states) used across the Applications Manager panes.

import SwiftUI
import VaderCleanerCore

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

extension ApplicationsManagerEmptyState {
    /// An empty state that answers for why the list is empty. `detail` is the
    /// pane's own all-clear, used only when nothing is hiding any rows.
    init(reason: ManagerEmptyReason, icon: String, title: String, detail: String) {
        switch reason {
        case .noSearchMatches:
            self.init(
                icon: "magnifyingglass",
                title: title,
                detail: String(localized: "Nothing here matches your search.", comment: "Manager empty state when a search finds nothing.")
            )
        case .nothingSelected:
            self.init(
                icon: icon,
                title: title,
                detail: String(localized: "Nothing is selected.", comment: "Manager empty state for an empty Selected facet.")
            )
        case .nothingFound:
            self.init(icon: icon, title: title, detail: detail)
        }
    }
}

/// Takes the place of a list that couldn't be loaded. An empty list here says
/// nothing about what's on the Mac, so it must not look like an all-clear.
struct ApplicationsManagerFailureState: View {
    let title: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text(title).font(.title2.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(String(localized: "Try Again", comment: "Retry a list that failed to load."), action: onRetry)
                .accessibilityIdentifier("applications.manager.tryAgain")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The manager's result banner, above the footer: what the last removal did.
struct ApplicationsManagerNoticeBanner: View {
    let notice: ManagerNotice
    let onDismiss: () -> Void
    var onReinstallHelper: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
            Text(notice.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("applications.manager.notice")
            Spacer(minLength: 8)
            if notice.offersHelperReinstall, let onReinstallHelper {
                Button(String(localized: "Reinstall Helper", comment: "Recovery action when the privileged helper is unreachable."), action: onReinstallHelper)
            }
            Button(String(localized: "Dismiss", comment: "Dismiss a result banner."), action: onDismiss)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }
}

/// The "Select: All / None" control above a checkbox list. "All" means the rows
/// on screen, so it can never reach further than what the user can see.
struct ApplicationsManagerBulkSelectMenu: View {
    let state: ManagerBulkSelectState
    let onSelectAll: () -> Void
    let onSelectNone: () -> Void

    private var label: String {
        switch state {
        case .none: return String(localized: "None", comment: "None selected.")
        case .some: return String(localized: "Some", comment: "Some selected.")
        case .all:  return String(localized: "All", comment: "All selected.")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(String(localized: "Select:", comment: "Manager bulk-select label.")).foregroundStyle(.secondary)
            Menu {
                Button(String(localized: "All", comment: "Select all."), action: onSelectAll)
                Button(String(localized: "None", comment: "Deselect all."), action: onSelectNone)
            } label: {
                Text(label).foregroundStyle(.tint)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
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
