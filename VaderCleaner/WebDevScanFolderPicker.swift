// WebDevScanFolderPicker.swift
// Settings → Scanning control that chooses which folders the Web Development Junk project scan walks — the default common code directories, or a single folder picked via NSOpenPanel.

import SwiftUI
import AppKit

/// Lets the user choose which folders the scattered-project half of the Web
/// Development Junk scan walks. Shows the current scope as a capsule (folder
/// icon + name + chevron); the menu offers the default common code directories,
/// the currently-picked folder, and a "Choose folder…" entry that opens an
/// `NSOpenPanel`. The selection lives in `WebDevScanScopeStore`, which the live
/// scanner reads per scan.
struct WebDevScanFolderPicker: View {
    @Environment(WebDevScanScopeStore.self) private var scanScope

    /// Capsule shown when the default scope is active, where there is no single
    /// folder to name.
    private var defaultScopeName: String {
        String(localized: "My usual project folders", comment: "Web Development Junk scan scope: the common code directories under home.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where do you keep your coding projects?")
                .font(.subheadline.weight(.semibold))
            Text("Coding projects build up big folders of downloaded code that can be recreated any time. Point VaderCleaner at where yours live and it'll clear those out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            picker
                .padding(.top, 2)
        }
    }

    private var picker: some View {
        Menu {
            // The default scope — always present, checked when active.
            Button {
                scanScope.selectDefault()
            } label: {
                menuItemLabel(
                    title: defaultScopeName,
                    icon: Image(systemName: "folder.badge.gearshape"),
                    isSelected: scanScope.isDefault
                )
            }

            // The currently-picked folder, listed so the user can re-select it
            // after switching away (only when a custom folder is active).
            if let folder = scanScope.selectedFolderURL {
                Button {
                    scanScope.selectFolder(folder)
                } label: {
                    menuItemLabel(
                        title: folder.lastPathComponent,
                        icon: folderIcon(for: folder),
                        isSelected: true
                    )
                }
            }

            Divider()

            Button {
                presentFolderPanel()
            } label: {
                Label("Choose folder…", systemImage: "folder")
            }
        } label: {
            capsule
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("settings.scanning.webDevJunk.folderPicker")
    }

    /// The resting capsule: an icon, the active scope's name, and a trailing
    /// chevron.
    private var capsule: some View {
        HStack(spacing: 9) {
            scopeIcon
                .frame(width: 18, height: 18)
            Text(scanScope.selectedFolderURL?.lastPathComponent ?? defaultScopeName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 230, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    /// The capsule's leading glyph: the picked folder's real Finder icon, or a
    /// generic folder badge for the default scope.
    @ViewBuilder
    private var scopeIcon: some View {
        if let folder = scanScope.selectedFolderURL {
            folderIcon(for: folder)
        } else {
            Image(systemName: "folder.badge.gearshape")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }

    /// A menu row: a leading checkmark when active, an icon, and the name.
    private func menuItemLabel(title: String, icon: some View, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            if isSelected {
                Image(systemName: "checkmark")
            }
            icon
            Text(title)
        }
    }

    /// The genuine Finder icon for `url`, so the picker matches Finder.
    private func folderIcon(for url: URL) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    /// Opens a directory chooser; the picked folder becomes the scan scope.
    private func presentFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to check for leftover project files"
        panel.directoryURL = scanScope.selectedFolderURL
            ?? FileManager.default.homeDirectoryForCurrentUser

        // A sheet rather than `runModal()`: a nested modal session run from the
        // SwiftUI `Settings` scene takes the settings window down with it when
        // the panel dismisses.
        let handle: @Sendable (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            scanScope.selectFolder(url)
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }
}
