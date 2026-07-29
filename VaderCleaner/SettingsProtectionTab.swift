// SettingsProtectionTab.swift
// Protection tab for the Settings window — malware scan mode and the content types a scan inspects.

import SwiftUI
import AppKit

// MARK: - Protection tab

/// Scan options and scan-mode configuration for the Protection section. Bound to
/// `ProtectionSettingsStore`; the Malware view-model reads these at scan time so
/// a change takes effect on the next scan. The Configure Scan button on the
/// Protection intro opens Settings straight to this tab.
///
/// Single-column, on the shared settings grid: content-type checkboxes, then a
/// stack of selectable scan-mode cards — one per `ScanMode` — each showing its
/// speed, depth, and purpose, with the active mode highlighted in the accent.
struct ProtectionTab: View {

    @Environment(ProtectionSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
                SettingsPaneHeader(
                    symbol: "hand.raised",
                    title: "Protection",
                    subtitle: "Choose how closely VaderCleaner checks your Mac for malware."
                )

                VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                    scanOptionsSection

                    scanModeSection
                }
            }
            .padding(.horizontal, SettingsMetrics.horizontalPadding)
            .padding(.top, SettingsMetrics.topPadding)
            .padding(.bottom, SettingsMetrics.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Scan options

    private var scanOptionsSection: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 12) {
            Text("What to check")
                .font(.headline)

            Toggle("Look inside email attachments", isOn: $settings.scanEmailAttachments)
                .accessibilityIdentifier("protection.scanEmailAttachments")
            Toggle("Look inside zip files and other archives", isOn: $settings.scanArchives)
                .accessibilityIdentifier("protection.scanArchives")
            HStack(spacing: 8) {
                Toggle("Skip iCloud files already saved on this Mac", isOn: $settings.excludeDownloadedICloudFiles)
                    .accessibilityIdentifier("protection.excludeDownloadedICloudFiles")
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("Apple already checks the copies kept in iCloud, so skipping the ones downloaded here makes scans finish sooner.")
            }
        }
        .toggleStyle(.settingsCheckbox)
    }

    // MARK: Scan mode

    private var scanModeSection: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 12) {
            Text("How thorough to be")
                .font(.headline)

            VStack(spacing: 10) {
                ForEach(ScanMode.allCases) { mode in
                    ScanModeCard(
                        mode: mode,
                        isSelected: settings.scanMode == mode
                    ) {
                        settings.scanMode = mode
                    }
                    .accessibilityIdentifier("protection.scanMode.\(mode.rawValue)")
                }
            }
        }
    }
}

/// One selectable scan-mode option: a radio indicator, the mode's name with its
/// speed and depth as chips, and its purpose. The active card fills and outlines
/// in the settings accent. Tapping anywhere on the card selects the mode.
private struct ScanModeCard: View {

    let mode: ScanMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                radio
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(mode.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        chip(mode.speed)
                        chip(mode.depth)
                    }
                    Text(mode.purpose)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected
                          ? Color.settingsAccent.opacity(0.14)
                          : Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.settingsAccent.opacity(0.85) : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(VaderMotion.control, value: isSelected)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var radio: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? Color.settingsAccent : Color.secondary.opacity(0.5),
                    lineWidth: 1.5
                )
            if isSelected {
                Circle()
                    .fill(Color.settingsAccent)
                    .padding(4)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .fixedSize()
    }
}
