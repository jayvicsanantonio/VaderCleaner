// CareScanChecklistView.swift
// The scanning experience: a grid of six care-domain tiles — corner art over an accent bloom, a traveling border while a domain scans — each filling in with a plain-language result the moment its sub-scans genuinely finish.

import SwiftUI

/// The `.scanning` surface: one tile per care domain in a fixed grid, styled
/// like the results dashboard's cards (the domain's 3D art in the top-right
/// corner over a soft bloom of its accent). Tiles never reorder; a domain
/// being scanned runs a light around its edge in its accent colour, and its
/// result lands as it truly completes — including grey "Skipped" and amber
/// "Couldn't check" so a problem never hides behind an all-clear.
struct CareScanChecklistView: View {

    var viewModel: SmartScanViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 14),
        count: 3
    )

    var body: some View {
        VStack(spacing: 28) {
            header
            // One container so the six glass tiles resolve in a single pass.
            GlassEffectContainer(spacing: 14) {
                LazyVGrid(columns: Self.gridColumns, spacing: 14) {
                    ForEach(viewModel.checklistDomains, id: \.self) { domain in
                        CareScanTile(domain: domain, status: viewModel.domainStatus(domain))
                            .frame(height: 168)
                    }
                }
            }
            .frame(maxWidth: 960)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : VaderMotion.surface,
            value: viewModel.checklistDomains.map { viewModel.domainStatus($0) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.scanning")
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(String(localized: "Checking your Mac…", comment: "Scanning checklist headline."))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            if viewModel.scannedItemCount > 0 {
                Text(String.localizedStringWithFormat(
                    String(
                        localized: "Looked at %d items so far",
                        comment: "Scanning checklist running total of items examined."
                    ),
                    viewModel.scannedItemCount
                ))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityIdentifier("smartScan.scanning.detail")
            } else {
                Text(String(
                    localized: "This runs in the background — feel free to keep working.",
                    comment: "Scanning checklist reassurance line before counts arrive."
                ))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

/// One domain's tile: title top-left, the domain's art over its accent bloom
/// top-right, and the live status bottom-left — waiting → checking (with a
/// traveling edge light) → plain-language result / Skipped / Couldn't check.
private struct CareScanTile: View {

    let domain: CareDomain
    let status: SmartScanViewModel.DomainStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(domain.title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            statusContent
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Corner bloom + art beneath the text, matching the results cards:
        // a radial wash of the domain's accent with its 3D art on top.
        .background(artCorner)
        .vaderTileGlass()
        // A light travels the tile's edge for as long as this domain is being
        // scanned, so it reads as actively working even between count ticks.
        .overlay {
            if isRunning {
                CareScanTileBorder(tint: domain.scanArtTint)
            }
        }
        .opacity(isDimmed ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("smartScan.scanning.tile.\(domain.rawValue)")
    }

    // MARK: - Pieces

    /// Soft accent bloom in the top-right corner with the domain's art over
    /// it — the glow takes the art's own colour so each tile reads as its
    /// section. Waiting/skipped tiles desaturate so activity draws the eye.
    private var artCorner: some View {
        RadialGradient(
            colors: [domain.scanArtTint.opacity(isDimmed ? 0.0 : 0.55), domain.scanArtTint.opacity(0.0)],
            center: .topTrailing,
            startRadius: 0,
            endRadius: 200
        )
        .overlay(alignment: .topTrailing) {
            Image(domain.scanArtAsset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .padding(6)
                .saturation(isDimmed ? 0.0 : 1.0)
                .opacity(isDimmed ? 0.55 : 1.0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch status {
        case .pending:
            Text(String(localized: "Waiting…", comment: "Checklist tile line before its domain starts."))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        case .running(let items):
            Text(String(localized: "Checking…", comment: "Checklist tile line while its domain scans."))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if items > 0 {
                Text(String.localizedStringWithFormat(
                    String(localized: "%d items", comment: "Checklist tile live item count."),
                    items
                ))
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
                .contentTransition(.numericText())
            }
        case .finished(let line):
            Text(line)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .skipped:
            Text(String(localized: "Skipped", comment: "Checklist tile label for a domain excluded from this run."))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            Text(String(
                localized: "Not in your scan settings.",
                comment: "Checklist tile caption for a domain excluded in settings."
            ))
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        case .failed:
            Text(String(localized: "Couldn't check", comment: "Checklist tile label when a domain's scan failed."))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            Text(String(
                localized: "We'll still show everything else.",
                comment: "Checklist tile caption when a domain's scan failed."
            ))
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private var isDimmed: Bool {
        switch status {
        case .pending, .skipped: return true
        case .running, .finished, .failed: return false
        }
    }
}

/// An animated stroke around a scanning tile: a soft segment of the domain's
/// accent glides smoothly around the edge over a steady dim ring of the same
/// tint. The segment travels along the rounded-rect path itself — an animated
/// dash phase — so it keeps a constant speed through the corners instead of
/// whipping across them the way a centre-based sweep does. Reduce Motion
/// drops the travel and holds the steady edge so the "still working" read
/// survives without movement.
private struct CareScanTileBorder: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cornerRadius: CGFloat = 24
    private let lineWidth: CGFloat = 2
    /// Seconds for the moving segment to travel one full loop of the edge.
    private let period: TimeInterval = 4

    var body: some View {
        if reduceMotion {
            // No travel: a steady tinted edge still reads as "active".
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(tint.opacity(0.6), lineWidth: lineWidth)
        } else {
            GeometryReader { proxy in
                let perimeter = perimeter(of: proxy.size)
                // One soft segment (~a third of the edge) with a matching gap,
                // so a single band travels the whole path and wraps through the
                // start seam without a jump.
                let segment = perimeter / 3
                // Drive the travel from the animation clock, not an animatable
                // `@State`. A `repeatForever` animation restarts whenever the
                // tile re-renders — and progress ticks re-render it constantly —
                // which snapped the segment back mid-loop. A clock-derived phase
                // is immune to re-renders and always completes full revolutions.
                let dash = [segment, perimeter - segment]
                TimelineView(.animation) { context in
                    let dashPhase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period * perimeter
                    ZStack {
                        // Steady dim ring so the edge is never dark.
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(tint.opacity(0.3), lineWidth: lineWidth)
                        // Soft halo behind the travelling segment: a wide,
                        // translucent stroke fakes the glow. It replaces a
                        // per-frame `.blur`, whose full-tile offscreen pass over
                        // the glass material every frame dropped frames.
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .inset(by: lineWidth / 2)
                            .stroke(
                                tint.opacity(0.35),
                                style: StrokeStyle(
                                    lineWidth: lineWidth * 4,
                                    lineCap: .round,
                                    dash: dash,
                                    dashPhase: dashPhase
                                )
                            )
                        // Crisp core of the travelling segment.
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .inset(by: lineWidth / 2)
                            .stroke(
                                tint,
                                style: StrokeStyle(
                                    lineWidth: lineWidth,
                                    lineCap: .round,
                                    dash: dash,
                                    dashPhase: dashPhase
                                )
                            )
                    }
                }
            }
        }
    }

    /// Length of the *stroked* edge — the rounded rect inset by `lineWidth / 2`,
    /// which is the path `.strokeBorder` and `.inset(by:)` actually trace — not
    /// the outer bounds. Measuring the outer rect makes the dash pattern
    /// ~`π · lineWidth` longer than the real path, so the single travelling
    /// segment fails to tile the closed path and visibly snaps back each time it
    /// crosses the rounded-rect's seam. The four straight runs are unchanged by
    /// the inset; only the corner arc radius shrinks by `lineWidth / 2`.
    private func perimeter(of size: CGSize) -> CGFloat {
        let insetRadius = cornerRadius - lineWidth / 2
        let straight = 2 * (size.width - lineWidth - 2 * insetRadius)
            + 2 * (size.height - lineWidth - 2 * insetRadius)
        let corners = 2 * .pi * insetRadius
        return straight + corners
    }
}

/// Per-domain art and accent for the scanning grid — the same section
/// artwork and accents the rest of the app uses, so each tile reads
/// instantly as its section.
private extension CareDomain {
    var scanArtAsset: String {
        switch self {
        case .systemJunk: return "systemJunk"
        case .malware: return "malwareRemoval"
        case .performance: return "performance"
        case .applications: return "applications"
        case .myClutter: return "largeOldFiles"
        case .browserPrivacy: return "scanBadgeCookies"
        }
    }

    var scanArtTint: Color {
        switch self {
        case .systemJunk: return NavigationSection.systemJunk.theme.accent
        case .malware: return NavigationSection.malwareRemoval.theme.accent
        case .performance: return NavigationSection.performance.theme.accent
        case .applications: return NavigationSection.applications.theme.accent
        case .myClutter: return NavigationSection.largeOldFiles.theme.accent
        case .browserPrivacy: return .indigo
        }
    }
}
