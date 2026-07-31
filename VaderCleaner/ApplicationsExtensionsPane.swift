// ApplicationsExtensionsPane.swift
// The Applications Manager's Extensions pane: the facet column plus the extensions and plug-ins list.

import SwiftUI

/// Middle-pane facet for the Extensions pane.
enum ExtensionsFacet: Hashable {
    case all
    case selected
    case type(ExtensionType)
}

/// The Extensions pane — the facet column plus the extensions/plug-ins list.
/// Extracted from `ApplicationsManagerView`; the facet, selection, and memoized
/// list are owned by the parent (the footer's Remove action reads the selection)
/// and passed in as bindings.
struct ExtensionsPaneView: View {
    let extensionsManagerViewModel: ExtensionsManagerViewModel
    let search: String
    @Binding var facet: ExtensionsFacet
    @Binding var selection: Set<ExtensionItem.ID>
    @Binding var displayed: [ExtensionItem]

    var body: some View {
        HStack(spacing: 0) {
            middleColumn.frame(width: 320)
            Divider().opacity(0.4)
            rightColumn.frame(maxWidth: .infinity)
        }
    }

    // MARK: Middle (facets)

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Extensions", comment: "Extensions pane title."),
                description: String(localized: "Manage the add-ons and plug-ins installed into your browsers and apps.", comment: "Extensions pane description.")
            )
            ScrollView { facets.padding(8) }
        }
    }

    private var facets: some View {
        let grouped = extensionsManagerViewModel.groupedByType
        return VStack(spacing: 4) {
            facetRow(.all, String(localized: "All Extensions", comment: "Extensions facet."), extensionsManagerViewModel.items.count)
            facetRow(.selected, String(localized: "Selected", comment: "Extensions facet."), selection.count)

            if !grouped.isEmpty {
                ApplicationsManagerFacetSectionHeader(title: String(localized: "Categories", comment: "Extensions facet group header."))
                ForEach(grouped, id: \.0) { type, entries in
                    facetRow(.type(type), localizedExtensionType(type), entries.count)
                }
            }
        }
    }

    private func facetRow(_ target: ExtensionsFacet, _ label: String, _ count: Int) -> some View {
        ApplicationsManagerFacetRow(label: label, count: count, selected: facet == target) {
            facet = target
        }
    }

    private func localizedExtensionType(_ type: ExtensionType) -> String {
        switch type {
        case .safariExtension:  return String(localized: "Safari Extensions", comment: "Extension category.")
        case .chromeExtension:  return String(localized: "Chrome Extensions", comment: "Extension category.")
        case .firefoxExtension: return String(localized: "Firefox Extensions", comment: "Extension category.")
        case .mailPlugin:       return String(localized: "Mail Plugins", comment: "Extension category.")
        case .internetPlugin:   return String(localized: "Browser Plug-ins", comment: "Extension category.")
        }
    }

    private var rightPaneTitle: String {
        switch facet {
        case .all:              return String(localized: "All Extensions", comment: "Extensions right pane title.")
        case .selected:         return String(localized: "Selected", comment: "Extensions right pane title.")
        case .type(let t):      return localizedExtensionType(t)
        }
    }

    private var rightPaneDescription: String {
        switch facet {
        case .all:              return String(localized: "Every extension and plug-in installed on this Mac.", comment: "Extensions right pane description.")
        case .selected:         return String(localized: "Extensions you've chosen to remove.", comment: "Extensions right pane description.")
        case .type(let t):
            switch t {
            case .safariExtension:  return String(localized: "Extensions installed in Safari.", comment: "Safari extensions right pane description.")
            case .chromeExtension:  return String(localized: "Extensions installed in Google Chrome.", comment: "Chrome extensions right pane description.")
            case .firefoxExtension: return String(localized: "Extensions installed in Firefox.", comment: "Firefox extensions right pane description.")
            case .mailPlugin:       return String(localized: "Plug-ins installed in the Mail app.", comment: "Mail plugins right pane description.")
            case .internetPlugin:   return String(localized: "Legacy plug-ins used by web browsers.", comment: "Browser plug-ins right pane description.")
            }
        }
    }

    // MARK: Right (list)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(title: rightPaneTitle, description: rightPaneDescription)
            list
        }
    }

    private func recompute() {
        let items = extensionsManagerViewModel.items.filter { item in
            let matchesFacet: Bool
            switch facet {
            case .all:              matchesFacet = true
            case .selected:         matchesFacet = selection.contains(item.id)
            case .type(let type):   matchesFacet = item.type == type
            }
            guard matchesFacet else { return false }
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || item.name.localizedCaseInsensitiveContains(trimmed)
        }
        displayed = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var list: some View {
        // The recompute hooks stay attached to the outer Group so they fire in
        // both branches — otherwise an initially empty `displayed` would pin the
        // empty state and never recompute into the list.
        Group {
            if ApplicationsManagerModel.listState(
                isLoading: extensionsManagerViewModel.phase == .loading,
                isEmpty: displayed.isEmpty
            ) == .loading {
                ApplicationsManagerLoadingPane()
            } else if displayed.isEmpty {
                ApplicationsManagerEmptyState(
                    icon: "puzzlepiece.extension",
                    title: String(localized: "Extensions", comment: "Extensions empty-state title."),
                    detail: String(localized: "No browser extensions or plug-ins were found.", comment: "Extensions empty-state detail.")
                )
                .accessibilityIdentifier("applications.manager.extensions.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(displayed) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
                .accessibilityIdentifier("applications.manager.extensions.list")
            }
        }
        .onAppear { recompute() }
        .onChange(of: facet) { _, _ in recompute() }
        .onChange(of: search) { _, _ in recompute() }
        .onChange(of: extensionsManagerViewModel.items.map(\.id)) { _, _ in recompute() }
        // The selection only changes the visible list under the Selected facet.
        .onChange(of: selection) { _, _ in
            if facet == .selected { recompute() }
        }
    }

    private func row(_ item: ExtensionItem) -> some View {
        HStack(spacing: 12) {
            ApplicationsManagerCheckbox(selected: selection.contains(item.id)) {
                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            }
            Image(systemName: symbol(item.type))
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(localizedExtensionType(item.type)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SmartInsightsSparkle(itemTitle: item.name, accent: ApplicationsManagerChrome.accent, topic: .appExtension)
            Text(ApplicationsManagerChrome.byteText(item.size)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("applications.manager.extensions.row.\(item.id.path)")
    }

    private func symbol(_ type: ExtensionType) -> String {
        switch type {
        case .safariExtension:  return "safari"
        case .chromeExtension:  return "globe"
        case .firefoxExtension: return "globe"
        case .mailPlugin:       return "envelope"
        case .internetPlugin:   return "puzzlepiece.extension"
        }
    }
}
