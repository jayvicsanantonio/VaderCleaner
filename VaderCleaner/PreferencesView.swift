// PreferencesView.swift
// SwiftUI Settings window — General, Scanning, Notifications, Menu, Protection, and Ignore List tabs bound to the preference and settings stores.

import SwiftUI
import AppKit

/// Shared layout metrics so every tab's header and content line up on one grid
/// — the same left edge, top offset, and header-to-content gap across all six
/// panes, instead of each hardcoding its own padding.
enum SettingsMetrics {
    /// Matches the grouped `Form`'s card inset so the custom panes' content and
    /// the Form tabs' headers share one left edge.
    static let horizontalPadding: CGFloat = 20
    static let topPadding: CGFloat = 22
    static let bottomPadding: CGFloat = 22
    /// Gap between the pane header and the content below it.
    static let headerGap: CGFloat = 20
    /// Gap between stacked sections within a pane.
    static let sectionGap: CGFloat = 26
}

extension Color {
    /// The Settings window's accent — the Smart Care section's violet, deepened
    /// and slightly desaturated so it reads rich rather than neon as a fill,
    /// tint, or selection highlight, and carries white glyphs and labels at a
    /// comfortable contrast (~5:1 vs the raw hue's ~3.8:1). The raw section
    /// accent stays too bright to sit under white as a solid background.
    static let settingsAccent = Color(red: 0.55, green: 0.30, blue: 0.85)
}

/// Root of the Settings scene. Splits the preference categories across a
/// `TabView` so the layout matches macOS's native Settings windows.
///
/// Each tab is a small, self-contained subview — they all read/write the same
/// `PreferencesStore` / `ExclusionsStore` environment objects, so users can
/// toggle anything in any order without orchestration. The whole window adopts
/// the Vader crimson as its control tint (checkboxes, switches, pickers,
/// selection) so the native macOS chrome still reads as part of the app.
struct PreferencesView: View {

    @Environment(SettingsRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            ScanningTab()
                .tabItem { Label("Scanning", systemImage: "desktopcomputer") }
                .tag(SettingsTab.scanning)

            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)

            MenuBarTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.menuBar)

            ProtectionTab()
                .tabItem { Label("Protection", systemImage: "hand.raised") }
                .tag(SettingsTab.protectionScan)

            ExclusionsTab()
                .tabItem { Label("Ignore List", systemImage: "nosign") }
                .tag(SettingsTab.exclusions)
        }
        // The Smart Care violet carries through every SwiftUI control in the
        // window without fighting the system's Settings chrome.
        .tint(.settingsAccent)
        // Fixed size so all tabs share the same window and it doesn't jump as
        // the user switches tabs. The width accommodates the Scanning tab's
        // two-pane Smart Care layout. The height is sized for the content-rich
        // panes (Scanning, Notifications, Protection); those with more rows than
        // fit scroll inside their own `ScrollView`, so the sparse tabs (General,
        // Menu) don't have to carry a cavernous empty window.
        .frame(width: 620, height: 600)
    }
}

// MARK: - Shared chrome

/// A consistent pane header — a glossy circular icon beside a title and an
/// optional one-line description. Gives every tab the same branded anchor so the
/// window reads as one family rather than six unrelated forms.
struct SettingsPaneHeader: View {

    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 14) {
            SettingsBadgeIcon(symbol: symbol)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A glossy circular badge rendered at runtime: a top-lit violet orb with a
/// soft specular highlight, a fine rim, and a white SF Symbol — the Smart Care
/// look, sized for the settings pane headers. Rendering it in SwiftUI keeps the
/// six tab icons in one recolourable family with no baked assets to maintain.
struct SettingsBadgeIcon: View {

    let symbol: String
    var tint: Color = .settingsAccent
    var diameter: CGFloat = 42

    var body: some View {
        let base = tint
        ZStack {
            // Body: a vertical gradient so the orb reads lit from above.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [base.opacity(1.0), base.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Specular highlight pooled near the top — a restrained glossy sheen.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.38), .white.opacity(0)],
                        center: UnitPoint(x: 0.5, y: 0.28),
                        startRadius: 0,
                        endRadius: diameter * 0.5
                    )
                )
                .blendMode(.screen)

            // A fine bright rim gives the orb a crisp edge on the dark backdrop.
            Circle()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)

            Image(systemName: symbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                // A faint shadow keeps the white glyph legible on the brighter
                // section tints (green, teal) as well as the deep ones.
                .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
        }
        .frame(width: diameter, height: diameter)
        // A tight, low shadow for a little lift — not the wide halo the baked
        // artwork carried. Scaled to the badge so small tree icons don't glow.
        .shadow(color: .black.opacity(0.22), radius: diameter * 0.05, y: 1)
        .accessibilityHidden(true)
    }
}


/// The rounded Smart Care checkbox, matching the manager row cards
/// (`ManagerRowCheckbox`): an accent-filled rounded square with a white check
/// when on, a white dash when mixed, and a soft accent outline when off. Purely
/// visual — the wrappers below add the tap target, model wiring, and
/// accessibility so the same glyph serves both the Scanning tree and the
/// checkbox toggles.
struct SettingsCheckboxGlyph: View {

    let state: SmartScanSettingsStore.CheckState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let side: CGFloat = 18
    private static let corner: CGFloat = 5

    var body: some View {
        ZStack {
            switch state {
            case .on:
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(Color.settingsAccent)
                glyph("checkmark")
            case .mixed:
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(Color.settingsAccent)
                glyph("minus")
            case .off:
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(Color.settingsAccent.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .animation(VaderMotion.control, value: state)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            // The mark pops in from a smaller scale with the control spring, so
            // ticking a box answers with a little bounce; Reduce Motion fades.
            .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
    }
}

/// A tappable tri-state checkbox for the Scanning tree. Reports its on/off state
/// through accessibility so the identifier-based UI tests still read a value.
struct SettingsTreeCheckbox: View {

    let state: SmartScanSettingsStore.CheckState
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsCheckboxGlyph(state: state)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(state == .off ? "0" : "1")
        .accessibilityAddTraits(state == .off ? [] : .isSelected)
    }
}

/// Renders SwiftUI `Toggle`s in the Notifications and Protection panes with the
/// same rounded Smart Care checkbox, so every checkbox in Settings matches the
/// manager rows. The whole row is the tap target.
struct SettingsCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                SettingsCheckboxGlyph(state: configuration.isOn ? .on : .off)
                configuration.label
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == SettingsCheckboxToggleStyle {
    /// The rounded Smart Care checkbox toggle style used across Settings.
    static var settingsCheckbox: SettingsCheckboxToggleStyle { SettingsCheckboxToggleStyle() }
}
