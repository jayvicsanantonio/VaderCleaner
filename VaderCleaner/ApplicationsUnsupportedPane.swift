// ApplicationsUnsupportedPane.swift
// The Applications Manager's Unsupported pane: the apps that cannot run on this macOS, each with a checkbox.

import SwiftUI

/// The Unsupported pane — a single-section column plus the list of apps that
/// can't run on this macOS, each with a checkbox. Selection lives on
/// `ApplicationsViewModel` (the footer's Move to Trash action reads it), the
/// same model the Leftovers pane uses.
struct UnsupportedPaneView: View {
    let viewModel: ApplicationsViewModel
    let result: ApplicationsScanResult
    let iconCache: AppIconCache
    let search: String

    var body: some View {
        HStack(spacing: 0) {
            middleColumn.frame(width: 320)
            Divider().opacity(0.4)
            rightColumn.frame(maxWidth: .infinity)
        }
        .task(id: result.unsupportedApps.map(\.id)) {
            await iconCache.preloadIcons(for: result.unsupportedApps.map(\.app.bundleURL))
        }
    }

    // MARK: Middle (single section)

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Unsupported", comment: "Unsupported pane title."),
                description: String(localized: "These apps won't run on this version of macOS — their code is built only for older architectures.", comment: "Unsupported pane description.")
            )
            ScrollView {
                VStack(spacing: 4) {
                    ApplicationsManagerSelectableRow(selected: true, action: {}) {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 28)
                            Text(String(localized: "All Unsupported", comment: "Unsupported section."))
                                .font(.body.weight(.medium))
                            Spacer()
                            Text("\(result.unsupportedApps.count)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: Right (list)

    private var displayedApps: [UnsupportedApp] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result.unsupportedApps }
        return result.unsupportedApps.filter {
            $0.app.name.localizedCaseInsensitiveContains(trimmed)
                || $0.app.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Unsupported Applications", comment: "Unsupported list title."))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "Move apps that can't run on this Mac to the Trash. Only the app bundle is removed here; full cleanup is available in the Uninstaller.", comment: "Unsupported list description."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(String(localized: "Select:", comment: "Manager bulk-select label.")).foregroundStyle(.secondary)
                    Menu {
                        Button(String(localized: "All", comment: "Select all.")) { viewModel.selectAllUnsupportedApps() }
                        Button(String(localized: "None", comment: "Deselect all.")) { viewModel.clearUnsupportedAppSelection() }
                    } label: {
                        Text(result.unsupportedApps.contains(where: viewModel.isUnsupportedAppSelected)
                             ? String(localized: "Some", comment: "Some selected.")
                             : String(localized: "None", comment: "None selected."))
                        .foregroundStyle(.tint)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        if ApplicationsManagerModel.listState(
            isLoading: viewModel.phase == .scanning,
            isEmpty: result.unsupportedApps.isEmpty
        ) == .loading {
            ApplicationsManagerLoadingPane()
        } else if result.unsupportedApps.isEmpty {
            ApplicationsManagerEmptyState(
                icon: "checkmark.seal.fill",
                title: String(localized: "Unsupported", comment: "Unsupported empty-state title."),
                detail: String(localized: "Every installed app can run on this version of macOS.", comment: "Unsupported empty-state detail.")
            )
            .accessibilityIdentifier("applications.manager.unsupported.empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(displayedApps) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .accessibilityIdentifier("applications.manager.unsupported.list")
        }
    }

    private func row(_ entry: UnsupportedApp) -> some View {
        HStack(spacing: 12) {
            ApplicationsManagerCheckbox(selected: viewModel.isUnsupportedAppSelected(entry)) {
                viewModel.toggleUnsupportedApp(entry)
            }
            Image(nsImage: iconCache.icon(for: entry.app.bundleURL))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.app.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(reasonText(entry)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SmartInsightsSparkle(itemTitle: entry.app.name, accent: ApplicationsManagerChrome.accent, topic: .application)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggleUnsupportedApp(entry) }
        .padding(12)
        .managerRowCard()
        .accessibilityIdentifier("applications.manager.unsupported.row.\(entry.app.bundleID)")
    }

    private func reasonText(_ entry: UnsupportedApp) -> String {
        switch entry.reason {
        case .incompatibleArchitecture:
            return String(localized: "Won't run on this macOS — built for an older architecture", comment: "Reason label for an unsupported app with no runnable architecture.")
        }
    }
}
