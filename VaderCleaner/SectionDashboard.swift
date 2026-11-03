// SectionDashboard.swift
// The page every section dashboard shares — a Start Over bar, the section hero with a finding-led headline and one action, and the bento card grid — so Cleanup, My Clutter, Protection, Performance and Applications read as one app.

import SwiftUI
import VaderCleanerCore

/// The header's single action pill ("Review All Junk", "Manage Privacy Items", …).
struct DashboardHeaderAction {
    let title: String
    let identifier: String
    let action: () -> Void
}

/// The top-left control that discards the results and returns to the
/// section's intro.
struct DashboardStartOver {
    let identifier: String
    /// Held off while something is still changing the Mac: a scan started then
    /// could list a file a removal is about to move.
    var isDisabled = false
    let action: () -> Void
}

/// One section's results page: Start Over in the top-left corner, then the
/// section hero, a headline that says what the scan found, a subheadline, and
/// one action pill, above a `DashboardGrid` that takes the remaining height.
/// Owns every inset and spacing, so the five dashboards line up when the user
/// moves between them. Also puts the section's orb palette in the environment,
/// so every `DashboardOrb` beneath it wears the section's colour.
struct SectionDashboard<Footnote: View, Grid: View>: View {
    let section: NavigationSection
    let headline: String
    let subheadline: String
    /// Identifier on the headline, for the UI tests that read it.
    let headlineIdentifier: String
    let headerAction: DashboardHeaderAction
    let startOver: DashboardStartOver
    /// Identifier on the whole dashboard.
    let identifier: String
    /// A line under the action pill for the section's own status (Protection's
    /// definitions age, Cleanup's note about junk no card shows).
    let footnote: Footnote
    let grid: Grid

    init(
        section: NavigationSection,
        headline: String,
        subheadline: String,
        headlineIdentifier: String,
        headerAction: DashboardHeaderAction,
        startOver: DashboardStartOver,
        identifier: String,
        @ViewBuilder footnote: () -> Footnote,
        @ViewBuilder grid: () -> Grid
    ) {
        self.section = section
        self.headline = headline
        self.subheadline = subheadline
        self.headlineIdentifier = headlineIdentifier
        self.headerAction = headerAction
        self.startOver = startOver
        self.identifier = identifier
        self.footnote = footnote()
        self.grid = grid()
    }

    var body: some View {
        VStack(spacing: 0) {
            startOverBar
            VStack(spacing: 20) {
                header
                grid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.dashboardOrbPalette, DashboardOrbPalette.for(section))
        .accessibilityIdentifier(identifier)
    }

    /// Uses an explicit `HStack(Image, Text)` rather than `Label` so it surfaces
    /// reliably as a button in XCUITest.
    private var startOverBar: some View {
        HStack {
            Button(action: startOver.action) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(String(
                        localized: "Start Over",
                        comment: "Button on a section dashboard that discards the results and returns to the section's intro."
                    ))
                }
            }
            .buttonStyle(.plain)
            .disabled(startOver.isDisabled)
            .accessibilityIdentifier(startOver.identifier)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private var header: some View {
        VStack(spacing: 14) {
            if let hero = SectionPresentation.for(section)?.heroAssetName {
                Image(hero)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 140, maxHeight: 140)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 4) {
                Text(headline)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier(headlineIdentifier)
                Text(subheadline)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .multilineTextAlignment(.center)

            Button(action: headerAction.action) {
                Text(headerAction.title)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.vaderTileGlass)
            .controlSize(.large)
            .accessibilityIdentifier(headerAction.identifier)

            footnote
        }
    }
}

extension SectionDashboard where Footnote == EmptyView {
    init(
        section: NavigationSection,
        headline: String,
        subheadline: String,
        headlineIdentifier: String,
        headerAction: DashboardHeaderAction,
        startOver: DashboardStartOver,
        identifier: String,
        @ViewBuilder grid: () -> Grid
    ) {
        self.init(
            section: section,
            headline: headline,
            subheadline: subheadline,
            headlineIdentifier: headlineIdentifier,
            headerAction: headerAction,
            startOver: startOver,
            identifier: identifier,
            footnote: { EmptyView() },
            grid: grid
        )
    }
}

// MARK: - Grid

/// Places a dashboard's ranked tiles on the shared bento layout
/// (`DashboardGridLayout`): the lead in the first column, the rest beside it.
/// Each card is told its role so it can decide how much to show.
struct DashboardGrid<Tile: Identifiable, Card: View>: View {
    let tiles: [Tile]
    @ViewBuilder let card: (Tile, DashboardTileRole) -> Card

    var body: some View {
        // One container so adjacent glass tiles sample each other and refract
        // consistently. Its spacing stays below the grid gap: glass shapes
        // closer than that melt into one blob, and the tiles must stay discrete.
        GlassEffectContainer(spacing: 8) {
            GeometryReader { geo in
                let slots = DashboardGridLayout.slots(count: tiles.count, in: geo.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        let slot = slots[index]
                        card(tile, slot.role)
                            .frame(width: slot.frame.width, height: slot.frame.height)
                            .offset(x: slot.frame.minX, y: slot.frame.minY)
                    }
                }
            }
        }
    }
}
