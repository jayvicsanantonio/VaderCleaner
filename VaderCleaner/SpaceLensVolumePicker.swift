// SpaceLensVolumePicker.swift
// The Space Lens intro's scan-location selector — a translucent capsule showing the chosen volume or folder, with a menu listing the Mac's mounted volumes plus a "Choose folder…" option for any directory the next scan will walk.

import SwiftUI
import AppKit

/// Lets the user choose what the Space Lens scan walks: one of the Mac's
/// mounted volumes (the boot volume by default) or any folder picked via
/// "Choose folder…". Shows the current selection as a capsule (icon + name +
/// chevron). The choice lives on `DiskScannerViewModel.selectedVolumeURL`,
/// which `beginScan()` reads as the scan root.
struct SpaceLensVolumePicker: View {
    @Environment(DiskScannerViewModel.self) private var viewModel

    /// Section accent, used to tint the menu chevron so the control reads as
    /// part of the Space Lens intro.
    let accent: Color

    var body: some View {
        Menu {
            // Rebuilt each time the menu opens, so a drive plugged in after
            // launch shows up without relaunching.
            ForEach(mountedVolumes(), id: \.self) { url in
                Button {
                    viewModel.selectedVolumeURL = url
                } label: {
                    menuItemLabel(url: url, isSelected: isActive(url))
                }
            }

            // The active folder (when it isn't a mounted volume), shown checked
            // so the menu reflects the current selection. Already selected, so
            // the row is a no-op marker rather than an action.
            if !selectionIsMountedVolume() {
                Divider()
                Button {} label: {
                    menuItemLabel(url: viewModel.selectedVolumeURL, isSelected: true)
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
        .accessibilityIdentifier("section.intro.spaceLens.volumePicker")
    }

    /// The resting capsule: the selected volume's real Finder icon, its name,
    /// and a trailing chevron — matching the reference design.
    private var capsule: some View {
        HStack(spacing: 9) {
            volumeIcon(for: viewModel.selectedVolumeURL)
                .frame(width: 18, height: 18)
            Text(displayName(for: viewModel.selectedVolumeURL))
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 230, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// A menu row: the volume's real icon, its name, and a leading checkmark
    /// when it is the active selection.
    private func menuItemLabel(url: URL, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            if isSelected {
                Image(systemName: "checkmark")
            }
            volumeIcon(for: url)
            Text(displayName(for: url))
        }
    }

    /// The genuine Finder icon for the volume mounted at `url`.
    private func volumeIcon(for url: URL) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    /// Whether `url` is the active scan volume, compared by standardized path.
    private func isActive(_ url: URL) -> Bool {
        url.standardizedFileURL.path == viewModel.selectedVolumeURL.standardizedFileURL.path
    }

    /// The selection's display name — a volume root shows its Finder volume
    /// name (e.g. "Macintosh HD"); a chosen folder shows its own folder name
    /// rather than the containing volume's.
    private func displayName(for url: URL) -> String {
        if isVolumeRoot(url) {
            if let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName {
                return name
            }
            return url.path == "/" ? "Macintosh HD" : url.lastPathComponent
        }
        return url.lastPathComponent
    }

    /// Whether `url` is a volume's root directory (so it should read as the
    /// volume name) rather than a folder inside one.
    private func isVolumeRoot(_ url: URL) -> Bool {
        if url.path == "/" { return true }
        let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
        return volumeURL?.standardizedFileURL.path == url.standardizedFileURL.path
    }

    /// Whether the active selection is one of the mounted volumes (vs a folder
    /// chosen via "Choose folder…").
    private func selectionIsMountedVolume() -> Bool {
        let selected = viewModel.selectedVolumeURL.standardizedFileURL.path
        return mountedVolumes().contains { $0.standardizedFileURL.path == selected }
    }

    /// Opens a directory chooser; the picked folder becomes the scan root.
    private func presentFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to map with Space Lens"
        panel.directoryURL = viewModel.selectedVolumeURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.selectedVolumeURL = url
    }

    /// The browsable, local volumes the user can scan, always including the
    /// boot volume so the default selection is offered even if the system
    /// enumeration omits it.
    private func mountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey, .volumeIsLocalKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let browsable = mounted.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (values?.volumeIsBrowsable ?? true) && (values?.volumeIsLocal ?? true)
        }

        let bootVolume = DiskScannerViewModel.volumeRootURL
        var ordered = browsable
        if !ordered.contains(where: { $0.standardizedFileURL.path == bootVolume.path }) {
            ordered.insert(bootVolume, at: 0)
        }
        return ordered
    }
}
