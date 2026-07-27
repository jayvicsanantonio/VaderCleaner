// SettingsExclusionsTab.swift
// Ignore List tab for the Settings window — the paths every scanner leaves alone, added and removed here.

import SwiftUI
import AppKit

// MARK: - Exclusions tab

struct ExclusionsTab: View {

    @Environment(ExclusionsStore.self) private var exclusions
    @State private var selection: Set<String> = []
    /// Rebuilt whenever the pane appears or the list changes, so the existence
    /// check touches disk on a change rather than on every render pass.
    @State private var entries: [ExclusionEntry] = []
    /// Highlights the list while a folder is dragged over it.
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
            SettingsPaneHeader(
                symbol: "nosign",
                title: "Ignore List",
                subtitle: "Anything you add here is left alone — no scan will touch it."
            )

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isDropTargeted
                                          ? Color.settingsAccent
                                          : Color(nsColor: .separatorColor),
                                          lineWidth: isDropTargeted ? 2 : 1)
                    )

                if entries.isEmpty {
                    emptyState
                } else {
                    List(selection: $selection) {
                        ForEach(entries) { entry in
                            ExclusionRow(entry: entry)
                                .tag(entry.path)
                                .contextMenu {
                                    Button("Reveal in Finder") { reveal(entry) }
                                        .disabled(!entry.exists)
                                    Button("Stop Ignoring") { remove([entry.path]) }
                                }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Dragging a folder in from Finder is the natural gesture for a
            // list like this; the + button stays for keyboard-driven use.
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls { exclusions.add(path: url.path) }
                refresh()
                return !urls.isEmpty
            } isTargeted: { isDropTargeted = $0 }
            .onAppear(perform: refresh)
            .onChange(of: exclusions.exclusions, refresh)

            HStack(spacing: 8) {
                Button {
                    presentAddPanel()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a file or folder for scans to leave alone")

                Button(role: .destructive) {
                    remove(selection)
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection.isEmpty)
                .help("Stop ignoring the selected items")

                if missingCount > 0 {
                    Button {
                        remove(Set(entries.filter { !$0.exists }.map(\.path)))
                    } label: {
                        Label("Clean Up", systemImage: "sparkles")
                    }
                    .help("Remove entries whose files no longer exist")
                }

                Spacer()

                if !entries.isEmpty {
                    Text(countLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.horizontalPadding)
        .padding(.top, SettingsMetrics.topPadding)
        .padding(.bottom, SettingsMetrics.bottomPadding)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "nosign")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Nothing is being ignored")
                .font(.headline)
            Text("Drag a file or folder here — or use the + button — and every scan will leave it alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    // MARK: Derived state

    private var missingCount: Int {
        entries.filter { !$0.exists }.count
    }

    private var countLabel: String {
        let total = entries.count
        let base = total == 1 ? "1 item" : "\(total) items"
        guard missingCount > 0 else { return base }
        return "\(base) · \(missingCount) missing"
    }

    // MARK: Actions

    /// Recomputes the rows, including the on-disk existence check. Called when
    /// the pane appears and whenever the stored list changes, rather than from
    /// the view body — the check touches the file system.
    private func refresh() {
        entries = ExclusionEntry.entries(for: exclusions.exclusions)
        // Drop any selection that no longer refers to a listed row.
        selection = selection.intersection(entries.map(\.path))
    }

    private func remove(_ paths: Set<String>) {
        for path in paths { exclusions.remove(path: path) }
        selection.subtract(paths)
        refresh()
    }

    private func reveal(_ entry: ExclusionEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    /// Presents an `NSOpenPanel` so the user can pick any files or folders.
    /// Whatever they pick gets added as an absolute path string — `ExclusionsStore`
    /// already dedupes so re-picking is harmless.
    ///
    /// Presented as a sheet on the Settings window rather than via `runModal()`.
    /// A nested modal session run from a SwiftUI `Settings` scene takes the
    /// settings window down with it when the panel dismisses; a sheet keeps the
    /// window's own event handling intact.
    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        panel.message = "Choose files or folders for scans to leave alone"

        // AppKit invokes the completion handler on the main thread, so
        // `assumeIsolated` states that rather than deferring the list refresh.
        let handle: @Sendable (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                for url in panel.urls { exclusions.add(path: url.path) }
                refresh()
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }
}

/// One Ignore List row: the item's own name with its location beneath, and a
/// clear marker when the path no longer exists. Showing the raw absolute path
/// as the headline buried the one word the user actually recognises.
private struct ExclusionRow: View {

    let entry: ExclusionEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.exists ? "folder" : "questionmark.folder")
                .foregroundStyle(entry.exists ? Color.secondary : Color.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.exists ? entry.location : "\(entry.location) — no longer there")
                    .font(.caption)
                    .foregroundStyle(entry.exists ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        // The full path stays available on hover, since the row now shows an
        // abbreviated form.
        .help(entry.path)
        .opacity(entry.exists ? 1 : 0.7)
    }
}
