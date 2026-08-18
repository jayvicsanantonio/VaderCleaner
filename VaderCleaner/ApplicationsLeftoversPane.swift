// ApplicationsLeftoversPane.swift
// The Applications Manager's Leftovers pane: the Installers / Leftover Files section column plus the matching file list.

import SwiftUI

/// Which sub-list the Leftovers pane shows in its right column.
enum LeftoverSection: Hashable {
    case installers
    case leftoverFiles
}

/// The Leftovers pane — the Installers / Leftover Files section column plus the
/// matching file list. Extracted from `ApplicationsManagerView`; the section
/// selection stays on the parent (the footer's Remove action reads it too) and
/// is passed in as a binding.
struct LeftoversPaneView: View {
    let viewModel: ApplicationsViewModel
    let result: ApplicationsScanResult
    let search: String
    let sort: AppManagerSort
    @Binding var section: LeftoverSection

    var body: some View {
        HStack(spacing: 0) {
            middleColumn.frame(width: 320)
            Divider().opacity(0.4)
            rightColumn.frame(maxWidth: .infinity)
        }
    }

    // MARK: Middle (sections)

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Leftovers", comment: "Leftovers pane title."),
                description: String(localized: "If you manually remove an application file, all of its related items remain on your system. VaderCleaner locates and removes these leftovers even if the main app is already gone.", comment: "Leftovers pane description.")
            )
            ScrollView { sections.padding(8) }
        }
    }

    private var sections: some View {
        VStack(spacing: 4) {
            sectionRow(.installers,
                       Image("installerDmg"),
                       String(localized: "Installers", comment: "Leftovers section."),
                       result.installationFilesTotalBytes)
            sectionRow(.leftoverFiles,
                       Image(systemName: "puzzlepiece.extension.fill"),
                       String(localized: "Leftover Files", comment: "Leftovers section."),
                       result.leftoversTotalBytes)
        }
    }

    private func sectionRow(_ target: LeftoverSection, _ icon: Image, _ label: String, _ bytes: Int64) -> some View {
        ApplicationsManagerSelectableRow(selected: section == target) {
            section = target
        } content: {
            HStack(spacing: 12) {
                icon.resizable().aspectRatio(contentMode: .fit).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.body.weight(.medium))
                    Text(ApplicationsManagerChrome.byteText(bytes)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: Right (file list)

    @ViewBuilder
    private var rightColumn: some View {
        switch section {
        case .installers:
            fileList(
                title: String(localized: "Unused DMG Files", comment: "Installers list title."),
                description: String(localized: "Save space by removing unneeded DMGs or other installation files of applications.", comment: "Installers list description."),
                rows: result.installationFiles.map { file in
                    DisplayRow(id: file.url.path, name: file.name, bytes: file.sizeBytes,
                               selected: viewModel.isInstallationFileSelected(file),
                               toggle: { viewModel.toggleInstallationFile(file) })
                },
                onSelectNone: viewModel.clearInstallationFileSelection,
                onSelectAll: { viewModel.selectAllInstallationFiles(ids: $0) },
                usesDiskIcon: true
            )
        case .leftoverFiles:
            fileList(
                title: String(localized: "Leftover Files", comment: "Leftover files list title."),
                description: String(localized: "Support files left behind by apps you've removed.", comment: "Leftover files list description."),
                rows: result.leftovers.map { group in
                    DisplayRow(id: group.bundleID, name: group.displayName, bytes: group.totalBytes,
                               selected: viewModel.isLeftoverSelected(group),
                               toggle: { viewModel.toggleLeftover(group) })
                },
                onSelectNone: viewModel.clearLeftoverSelection,
                onSelectAll: { viewModel.selectAllLeftovers(ids: $0) },
                usesDiskIcon: false
            )
        }
    }

    /// One row's display data for the Leftovers lists, with its own toggle so a
    /// single renderer serves both installers and leftover groups.
    private struct DisplayRow: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let selected: Bool
        let toggle: () -> Void
    }

    /// Applies the manager's search and sort to a section's rows. These
    /// were previously ignored here entirely — the search field was
    /// visible on this pane and typing in it did nothing.
    private func prepared(_ rows: [DisplayRow]) -> [DisplayRow] {
        let matched = rows.filter {
            ApplicationsManagerModel.matchesSearch(search, name: $0.name, identifier: $0.id)
        }
        // Files have a size but no last-opened date, so the header offers
        // name and size only — see `sortOptions(for:)`.
        switch sort {
        case .size:
            return matched.sorted { $0.bytes > $1.bytes }
        case .name, .lastOpened:
            return matched.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private func fileList(
        title: String,
        description: String,
        rows unpreparedRows: [DisplayRow],
        onSelectNone: @escaping () -> Void,
        onSelectAll: @escaping (Set<String>) -> Void,
        usesDiskIcon: Bool
    ) -> some View {
        let rows = prepared(unpreparedRows)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(description).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(String(localized: "Select:", comment: "Manager bulk-select label.")).foregroundStyle(.secondary)
                    Menu {
                        Button(String(localized: "All", comment: "Select all.")) {
                            // The rows on screen, not the whole payload.
                            onSelectAll(Set(prepared(rows).map(\.id)))
                        }
                        Button(String(localized: "None", comment: "Deselect all.")) { onSelectNone() }
                    } label: {
                        Text(rows.contains(where: \.selected)
                             ? String(localized: "Some", comment: "Some selected.")
                             : String(localized: "None", comment: "None selected."))
                        .foregroundStyle(.tint)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            if rows.isEmpty {
                ApplicationsManagerEmptyState(
                    icon: "checkmark.seal.fill",
                    title: String(localized: "Nothing to remove", comment: "Empty leftovers list."),
                    detail: String(localized: "There are no items in this area.", comment: "Empty leftovers detail.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                ApplicationsManagerCheckbox(selected: row.selected, action: row.toggle)
                                if usesDiskIcon {
                                    Image("installerDmg").resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "folder.badge.minus").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 28)
                                }
                                Text(row.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                SmartInsightsSparkle(itemTitle: row.name, accent: ApplicationsManagerChrome.accent, topic: .fileOrFolder)
                                Text(ApplicationsManagerChrome.byteText(row.bytes)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(width: 72, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { row.toggle() }
                            .padding(12)
                            .managerRowCard()
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
        }
    }
}
