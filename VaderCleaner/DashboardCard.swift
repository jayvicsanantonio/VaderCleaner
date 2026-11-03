// DashboardCard.swift
// The one card every section dashboard draws — title, detail, a top-right badge, and Review / direct-action capsules — plus the glossy orb badge its category icons share.

import SwiftUI
import VaderCleanerCore

// MARK: - Card

/// One button on a dashboard card.
struct DashboardCardAction: Identifiable {
    /// `primary` is the solid white capsule, reserved for an action that
    /// changes the Mac straight from the card (Clean, Remove). Everything else —
    /// opening a list to review, stopping or rerunning a scan — is a
    /// `secondary` glass capsule.
    enum Prominence {
        case secondary
        case primary
    }

    let title: String
    let prominence: Prominence
    let identifier: String
    let action: () -> Void

    var id: String { identifier }
}

/// A dashboard tile: a size- or count-led title, an optional detail line, a
/// badge in the top-right corner, and its actions pinned bottom-trailing. The
/// lead tile trades the corner badge for a large centered illustration.
///
/// The card always keeps to the frame the grid gives it. When its content
/// would be taller, it drops the illustration first and then the detail, so
/// a small window loses decoration rather than spilling a card over its
/// neighbours.
struct DashboardCard<Accessory: View, Illustration: View>: View {
    let title: String
    let detail: String?
    let role: DashboardTileRole
    let actions: [DashboardCardAction]
    let accessory: Accessory
    let illustration: Illustration

    init(
        title: String,
        detail: String?,
        role: DashboardTileRole,
        actions: [DashboardCardAction] = [],
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder illustration: () -> Illustration
    ) {
        self.title = title
        self.detail = detail
        self.role = role
        self.actions = actions
        self.accessory = accessory()
        self.illustration = illustration()
    }

    /// Compact tiles share a row two-up, so they keep the denser headline to
    /// stop their titles wrapping at the grid's narrowest widths.
    static func titleFont(for role: DashboardTileRole) -> Font {
        role == .compact ? .headline : .title3.weight(.semibold)
    }

    /// Glass capsules first, then the white one, so the brightest button always
    /// sits at the trailing edge whatever order a section lists them in.
    static func orderedActions(_ actions: [DashboardCardAction]) -> [DashboardCardAction] {
        actions.filter { $0.prominence == .secondary } + actions.filter { $0.prominence == .primary }
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            if role == .lead {
                content(showsIllustration: true, showsDetail: true)
            }
            content(showsIllustration: false, showsDetail: true)
            content(showsIllustration: false, showsDetail: false)
        }
        .padding(20)
        // Both a minimum and a maximum, so the frame takes the grid's size
        // unconditionally. With only a maximum it grows to fit content taller
        // than the slot, and the card overlaps the one below.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .vaderTileGlass()
    }

    private func content(showsIllustration: Bool, showsDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(Self.titleFont(for: role))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsDetail, let detail {
                        Text(detail)
                            .font(.callout)
                            // Soft white rather than `.secondary`, which goes
                            // gray over the tinted glass.
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if !showsIllustration {
                    accessory
                }
            }
            Spacer(minLength: 12)
            if showsIllustration {
                illustration
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
            }
            actionRow
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let ordered = Self.orderedActions(actions)
        if !ordered.isEmpty {
            HStack(spacing: 10) {
                Spacer()
                ForEach(ordered) { action in
                    switch action.prominence {
                    case .secondary:
                        Button(action.title, action: action.action)
                            .buttonStyle(.vaderGlass)
                            .accessibilityIdentifier(action.identifier)
                    case .primary:
                        Button(action.title, action: action.action)
                            .buttonStyle(.vaderWhite)
                            .accessibilityIdentifier(action.identifier)
                    }
                }
            }
        }
    }
}

// MARK: - Reassurance

/// An "all good" tile backfilling a grid that has fewer real findings than
/// its minimum. Built from `DashboardCard` so it shares every other tile's
/// anatomy, with the content's symbol drawn as an orb and no actions.
struct DashboardReassuranceCard: View {
    let content: ReassuranceContent
    let role: DashboardTileRole

    var body: some View {
        DashboardCard(title: content.title, detail: content.detail, role: role) {
            DashboardOrb(symbol: content.icon)
        } illustration: {
            DashboardOrb(symbol: content.icon, size: DashboardOrb.illustrationSize)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recommendation.reassurance.\(content.id)")
    }
}

// MARK: - Badges

/// One of the glossy 3D badges baked into the asset catalog (Cleanup's
/// categories). The PNG carries its own drop shadow and fills about 80% of
/// its frame, which `DashboardOrb` matches.
struct DashboardBadge: View {
    let asset: String
    var size: CGFloat = DashboardOrb.accessorySize

    var body: some View {
        Image(asset)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A glossy orb with a white SF Symbol, drawn to the same recipe as the baked
/// badges (`Scripts/ScanBadges/generate_svgs.py`): a radial body gradient lit
/// from above, a gloss highlight, a faint rim, and a soft drop shadow. Lets a
/// category with no baked art wear the same badge as one that has it. Takes
/// its colours from the enclosing `SectionDashboard`.
struct DashboardOrb: View {
    /// Side of the badge in a card's top-right corner.
    static let accessorySize: CGFloat = 52
    /// Side of the badge centered in the lead card.
    static let illustrationSize: CGFloat = 150

    let symbol: String
    var size: CGFloat = accessorySize
    /// Pulses the glyph, for a tile whose work is still running.
    var isPulsing = false

    @Environment(\.dashboardOrbPalette) private var palette

    /// The baked badges draw a 196-unit orb on a 240-unit canvas, leaving the
    /// margin to their drop shadow; matching that keeps a drawn orb and a baked
    /// one the same visible size in the same frame.
    private var diameter: CGFloat { size * 196 / 240 }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    stops: [
                        .init(color: palette.light, location: 0),
                        .init(color: palette.mid, location: 0.55),
                        .init(color: palette.edge, location: 1),
                    ],
                    center: UnitPoint(x: 0.5, y: 0.36),
                    startRadius: 0,
                    endRadius: diameter * 0.66
                ))
            Ellipse()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.85), .white.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: diameter * 156 / 196, height: diameter * 92 / 196)
                .offset(y: -diameter * 48 / 196)
            Circle()
                .strokeBorder(.white.opacity(0.22), lineWidth: max(1, diameter / 98))
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: diameter / 98, y: diameter / 98)
                .symbolEffect(.pulse, options: .repeating, isActive: isPulsing)
        }
        .frame(width: diameter, height: diameter)
        .compositingGroup()
        .shadow(color: .black.opacity(0.32), radius: size * 8 / 240, y: size * 6 / 240)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The three gradient stops a `DashboardOrb` is lit with.
struct DashboardOrbPalette: Equatable {
    let light: Color
    let mid: Color
    let edge: Color

    private init(_ light: UInt32, _ mid: UInt32, _ edge: UInt32) {
        func color(_ hex: UInt32) -> Color {
            Color(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
        self.light = color(light)
        self.mid = color(mid)
        self.edge = color(edge)
    }

    // These mirror the badge generator's `COLORS`, so a drawn orb sits beside
    // a baked badge of the same colour without a visible seam.
    static let green = DashboardOrbPalette(0x7BE88A, 0x3FC24F, 0x1F8A32)
    static let pink = DashboardOrbPalette(0xFF9EC7, 0xEF4D8F, 0xB81E63)
    static let orange = DashboardOrbPalette(0xFFD089, 0xFB9B2E, 0xD2700C)
    static let blue = DashboardOrbPalette(0x9FC4FF, 0x3F8BF0, 0x1F5FC0)
    static let purple = DashboardOrbPalette(0xC9A8F5, 0x9A5FE0, 0x6A34B0)
    /// My Clutter's teal. The generator has no teal because no baked badge
    /// needs one.
    static let teal = DashboardOrbPalette(0x8FF0E4, 0x2CC7B9, 0x12877E)

    /// The palette matching each section's backdrop hue.
    static func `for`(_ section: NavigationSection) -> DashboardOrbPalette {
        switch section {
        case .systemJunk:       return .green
        case .largeOldFiles:    return .teal
        case .malwareRemoval:   return .pink
        case .performance:      return .orange
        case .applications:     return .blue
        case .healthMonitor:    return .blue
        case .smartScan, .spaceLens: return .purple
        }
    }
}

extension EnvironmentValues {
    /// The orb colours for the enclosing section dashboard.
    @Entry var dashboardOrbPalette: DashboardOrbPalette = .purple
}
