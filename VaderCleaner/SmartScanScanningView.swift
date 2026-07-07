// SmartScanScanningView.swift
// Smart Scan's staged loading screen — a hero card for the module being collected right now above a strip of compact module tiles that flip to their result summaries as each sub-scan lands.

import SwiftUI

/// The `.scanning` surface for Smart Scan: one module at a time takes the
/// hero card (headline, artwork in the module's accent wash, live progress
/// line) while the other modules wait as compact tiles that fill in with
/// result summaries the moment their sub-scan is collected. The five
/// sub-scans actually run concurrently — the staging follows the real
/// collection checkpoints in `SmartScanViewModel.scan()`, so every hand-off
/// the user sees corresponds to results genuinely landing.
struct SmartScanScanningView: View {
    var viewModel: SmartScanViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                ForEach(stripModules, id: \.self) { module in
                    SmartScanScanTile(
                        module: module,
                        state: viewModel.moduleScanStates[module] ?? .pending
                    )
                }
            }
            .frame(height: 132)

            if let active = viewModel.activeScanModule {
                SmartScanScanHero(module: active, viewModel: viewModel)
                    // Fresh identity per module so the hand-off crossfades
                    // between hero cards instead of morphing text in place.
                    .id(active)
                    .transition(VaderMotion.dashboardTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(VaderMotion.surface, value: viewModel.activeScanModule)
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
