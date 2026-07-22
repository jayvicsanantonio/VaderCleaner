// MyClutterFolderPicker.swift
// The My Clutter intro's folder selector — a translucent capsule showing the chosen scan folder, with a menu to switch back to home or pick any directory via NSOpenPanel.

import SwiftUI
import AppKit

/// Lets the user choose which folder the My Clutter scan walks. Shows the
/// current selection as a capsule (folder icon + name + chevron); the menu
/// offers the home folder, the currently-picked folder, and a "Choose folder…"
/// entry that opens an `NSOpenPanel`. The selection lives in
/// `MyClutterScanScopeStore`, which the live scanner reads per scan.
struct MyClutterFolderPicker: View {
    @Environment(MyClutterScanScopeStore.self) private var scanScope

    /// Where the picker is being shown. The intro sits on the section's tinted
    /// backdrop and uses a translucent capsule; Settings sits in a `Form` and
    /// needs the same chrome as the other settings controls, plus a heading
    /// explaining what the folder is for.
    enum Style {
        case intro
        case settings
    }

    /// Section accent, used to tint the menu chevron so the control reads as
    /// part of the My Clutter intro.
    let accent: Color
    var style: Style = .intro

    var body: some View {
        if style == .settings {
            VStack(alignment: .leading, spacing: 6) {
                Text("Which folder should VaderCleaner sort through?")
                    .font(.subheadline.weight(.semibold))
                Text("By default it looks through your home folder — Documents, Downloads, Desktop and the rest. Point it somewhere else to narrow the search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                picker
                    .padding(.top, 2)
            }
        } else {
            picker
        }
    }

    private var picker: some View {
        Menu {
            // The home folder — always present, checked when it's the active
            // scope.
            Button {
                scanScope.selectHome()
            } label: {
                menuItemLabel(
                    title: FileManager.default.homeDirectoryForCurrentUser.lastPathComponent,
                    url: FileManager.default.homeDirectoryForCurrentUser,
                    isSelected: scanScope.isHome
                )
            }

            // The currently-picked folder, listed so the user can re-select it
            // after switching away (only when a non-home folder is active).
            if !scanScope.isHome {
                Button {
                    scanScope.selectFolder(scanScope.selectedURL)
                } label: {
                    menuItemLabel(
                        title: scanScope.displayName,
                        url: scanScope.selectedURL,
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
        .accessibilityIdentifier(style == .settings
                                 ? "settings.scanning.myClutter.folderPicker"
                                 : "section.intro.myClutter.folderPicker")
    }

    /// The resting capsule: the selected folder's real Finder icon, its name,
    /// and a trailing chevron — matching the reference design. In Settings it
    /// wears the standard control chrome instead of the intro's translucent
    /// material, which reads as a smudge on a `Form` background.
    private var capsule: some View {
        HStack(spacing: 9) {
            folderIcon(for: scanScope.selectedURL)
                .frame(width: 18, height: 18)
            Text(scanScope.displayName)
                .font(.system(size: style == .settings ? 13 : 14, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style == .settings ? Color.secondary : accent)
        }
        .padding(.horizontal, style == .settings ? 12 : 14)
        .padding(.vertical, style == .settings ? 8 : 10)
        .frame(minWidth: 230, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: style == .settings ? 8 : 10, style: .continuous)
                .fill(style == .settings
                      ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                      : AnyShapeStyle(.ultraThinMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: style == .settings ? 8 : 10, style: .continuous)
                .strokeBorder(style == .settings
                              ? Color(nsColor: .separatorColor)
                              : Color.white.opacity(0.12),
                              lineWidth: 1)
        )
    }

    /// A menu row: the folder's real icon, its name, and a leading checkmark
    /// when it is the active selection.
    private func menuItemLabel(title: String, url: URL, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            if isSelected {
                Image(systemName: "checkmark")
            }
            folderIcon(for: url)
            Text(title)
        }
    }

    /// The genuine Finder icon for `url` (the home directory shows its
    /// house-in-folder icon), so the picker matches what the user sees in
    /// Finder.
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
        panel.message = "Choose a folder to scan for clutter"
        panel.directoryURL = scanScope.selectedURL

        // A sheet rather than `runModal()`: this picker now appears in Settings
        // as well, and a nested modal session run from the SwiftUI `Settings`
        // scene takes the settings window down with it on dismissal.
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
