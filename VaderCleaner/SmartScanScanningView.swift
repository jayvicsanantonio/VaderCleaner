// SmartScanScanningView.swift
// Smart Scan's staged loading screen — a hero card for the module being collected right now above a strip of compact module tiles that flip to their result summaries as each sub-scan lands.

import SwiftUI

/// The `.scanning` surface for Smart Scan: one module at a time takes the
/// hero card (headline, artwork in the module's accent wash, live progress
/// line) while the other modules wait as compact tiles that fill in with
/// result summaries the moment their sub-scan is collected. The five sub-scans
/// run one at a time in collection order, so the staging follows the work
/// genuinely running: at each hand-off the finishing hero recedes into its
/// strip slot and the next module's tile flies down into the hero slot, the
/// two swapping in place via a shared `matchedGeometryEffect`.
struct SmartScanScanningView: View {
    var viewModel: SmartScanViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Ties each module's compact strip tile to its hero card so the active
    /// module's frame animates between the two slots instead of crossfading.
    @Namespace private var heroNamespace

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                ForEach(stripModules, id: \.self) { module in
                    SmartScanScanTile(
                        module: module,
                        state: viewModel.moduleScanStates[module] ?? .pending
                    )
                    .matchedGeometryEffect(id: module, in: heroNamespace)
                }
            }
            .frame(height: 132)

            if let active = viewModel.activeScanModule {
                SmartScanScanHero(module: active, viewModel: viewModel)
                    // Share the active module's identity with its strip tile so
                    // the hero grows out of the tile's former slot; a fresh
                    // `.id` per module makes each hand-off an insert/remove the
                    // matched-geometry effect can fly rather than a text morph.
                    .matchedGeometryEffect(id: active, in: heroNamespace)
                    .id(active)
                    .transition(.opacity)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reduce Motion drops the fly-into-place travel to a plain swap.
        .animation(reduceMotion ? nil : VaderMotion.surface, value: viewModel.activeScanModule)
        .accessibilityIdentifier("smartScan.scanning")
    }

    /// Every module except the hero, in collection order, so the strip reads
    /// as the queue the scan is working through.
    private var stripModules: [SmartScanModule] {
        SmartScanViewModel.scanCollectionOrder.filter { $0 != viewModel.activeScanModule }
    }
}

/// The large card for the module being collected right now: headline, the
/// module's dashboard artwork over its accent wash, and a live progress line
/// fed by the sub-scan's own counters.
private struct SmartScanScanHero: View {
    let module: SmartScanModule
    var viewModel: SmartScanViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text(module.scanningHeadline)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Image(module.scanTileAsset)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
            Text(detail)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.75))
                .contentTransition(.numericText())
                .animation(.default, value: detail)
                .accessibilityIdentifier("smartScan.scanning.detail")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The module's accent washes the card so each hand-off recolours the
        // hero, clipped to the tile shape the glass beneath uses.
        .background(
            LinearGradient(
                colors: [module.scanTileTint.opacity(0.45), module.scanTileTint.opacity(0.08)],
                startPoint: .bottom,
                endPoint: .top
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
        )
        .vaderTileGlass()
        // A light travels the card's edge for as long as this module is the
        // one being collected, so the hero reads as actively working even when
        // its counter is momentarily still.
        .overlay(SmartScanScanBorder(tint: module.scanTileTint))
    }

    /// Live progress line for the hero, from the sub-scan's own counters.
    private var detail: String {
        switch module {
        case .systemJunk, .myClutter:
            // The two file walks share one combined walked-items tally.
            return ScanProgressFormatting.itemsScanned(viewModel.scannedItemCount)
        case .malware:
            return viewModel.malwareFilesScanned > 0
                ? ScanProgressFormatting.threatsScanned(viewModel.malwareFilesScanned)
                : String(
                    localized: "Matching against known signatures…",
                    comment: "Hero progress line while the malware scan has not yet reported a count."
                )
        case .performance:
            return String(
                localized: "Collecting login items and launch agents…",
                comment: "Hero progress line while the Performance sub-scan is collected."
            )
        case .applications:
            return viewModel.appsTotal > 0
                ? ScanProgressFormatting.appsChecked(viewModel.appsChecked, of: viewModel.appsTotal)
                : String(
                    localized: "Comparing app versions with new releases…",
                    comment: "Hero progress line while the update probe has not yet reported a count."
                )
        }
    }
}

/// An animated stroke around the hero card that signals the module is still
/// being scanned: a soft segment of the module's accent glides smoothly
/// around the tile's edge over a steady dim ring of the same tint. The
/// segment travels along the rounded-rect path itself — an animated dash
/// phase — so it keeps a constant speed through the corners instead of
/// whipping across them the way a centre-based sweep does. Reduce Motion
/// drops the travel and holds the steady edge so the "still working" read
/// survives without movement.
private struct SmartScanScanBorder: View {
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
                // hero re-renders, and the malware sub-scan re-renders it many
                // times a second (one tick per file clamscan checks), which
                // snapped the segment back mid-loop. A clock-derived phase is
                // immune to re-renders — it always completes full revolutions —
                // and multiplying by the live perimeter keeps it smooth as the
                // hero grows into place.
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
                        // per-frame `.blur`, whose full-card offscreen pass over
                        // the glass material every frame dropped frames on the
                        // longest scan (Malware) and read as a stutter.
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

/// One compact module tile in the strip above the hero: title and dimmed
/// artwork while the module waits its turn, the result summary once its
/// sub-scan lands, or a quiet "Skipped" for modules excluded from this run.
private struct SmartScanScanTile: View {
    let module: SmartScanModule
    let state: SmartScanModuleScanState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(module.scanTileTitle)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Image(module.scanTileAsset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .opacity(isFinished ? 1 : 0.5)
            }
            Spacer(minLength: 0)
            switch state {
            case .finished(let metric, let caption):
                Text(metric)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            case .skipped:
                Text(String(
                    localized: "Skipped",
                    comment: "Compact scanning-screen tile label for a module excluded from this run."
                ))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            case .pending, .running:
                // Title-only while the module waits its turn; the dimmed tile
                // itself reads as "queued".
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vaderTileGlass()
        .opacity(state == .pending ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("smartScan.scanning.tile.\(module.rawValue)")
    }

    private var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }
}

/// Per-module art, accent, title, and hero headline for the scanning screen —
/// mirroring the dashboard tiles' metadata in
/// `SmartScanResultsState.tileMeta` so both screens speak with one visual
/// identity per module.
private extension SmartScanModule {
    var scanTileAsset: String {
        switch self {
        case .systemJunk: return "systemJunk"
        case .malware: return "malwareRemoval"
        case .performance: return "performance"
        case .applications: return "applications"
        case .myClutter: return "largeOldFiles"
        }
    }

    var scanTileTint: Color {
        switch self {
        case .systemJunk: return NavigationSection.systemJunk.theme.accent
        case .malware: return NavigationSection.malwareRemoval.theme.accent
        case .performance: return NavigationSection.performance.theme.accent
        case .applications: return NavigationSection.applications.theme.accent
        case .myClutter: return NavigationSection.largeOldFiles.theme.accent
        }
    }

    var scanTileTitle: String {
        switch self {
        case .systemJunk:
            return String(localized: "Cleanup", comment: "Scanning-screen tile title for the System Junk module.")
        case .malware:
            return String(localized: "Protection", comment: "Scanning-screen tile title for the Malware module.")
        case .performance:
            return String(localized: "Performance", comment: "Scanning-screen tile title for the Performance module.")
        case .applications:
            return String(localized: "Applications", comment: "Scanning-screen tile title for the Applications module.")
        case .myClutter:
            return String(localized: "My Clutter", comment: "Scanning-screen tile title for the My Clutter module.")
        }
    }

    var scanningHeadline: String {
        switch self {
        case .systemJunk:
            return String(localized: "Looking for junk…", comment: "Hero headline while the System Junk sub-scan is collected.")
        case .malware:
            return String(localized: "Looking for threats…", comment: "Hero headline while the malware sub-scan is collected.")
        case .performance:
            return String(localized: "Examining your system…", comment: "Hero headline while the Performance sub-scan is collected.")
        case .applications:
            return String(localized: "Checking for updates…", comment: "Hero headline while the app-update sub-scan is collected.")
        case .myClutter:
            return String(localized: "Analyzing your storage…", comment: "Hero headline while the My Clutter sub-scan is collected.")
        }
    }
}
