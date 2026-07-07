// SmartScanView.swift
// Smart Scan feature view — the default landing section. Walks the scan → results → clean → done state machine of SmartScanViewModel, surfacing one summary card per orchestrated sub-module.

import SwiftUI

/// Detail view shown when the user selects "Smart Scan" in the sidebar (the
/// default landing section). Drives `SmartScanViewModel`'s state machine,
/// and within `.results` either renders the dashboard or pushes one of the
/// five tile-specific Review screens in place. The Review push is local
/// state (not a nested NavigationStack) so it never collides with the outer
/// section-slide transition in ContentView. The Performance Review uses
/// `onOpenPerformance` to jump to the standalone sidebar section.
struct SmartScanView: View {

    private var viewModel: SmartScanViewModel
    private let onOpenPerformance: () -> Void

    /// The tile whose Review screen is currently up, or `nil` if the
    /// dashboard is visible. State is local because Review is a transient
    /// UI mode, not a persisted part of the scan model.
    @State private var review: SmartScanModule?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the manager zoom anchors: the button that opened it, resolved
    /// by `openReview`. Also the point Back zooms the manager back into.
    @State private var managerAnchor: UnitPoint = .center
    /// The transition host's frame in global space, for mapping the opening
    /// click to `managerAnchor`.
    @State private var paneFrame: CGRect = .zero

    init(
        viewModel: SmartScanViewModel,
        onOpenPerformance: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onOpenPerformance = onOpenPerformance
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(phaseTransitionID)
            // The subtle scale-and-fade phase changes share: the incoming
            // surface settles forward from 97% while the outgoing recedes.
            // Review pushes are not phase changes — they swap inside
            // `resultsContent` with the manager zoom motion. Reduce Motion
            // keeps the plain crossfade.
            .transition(VaderMotion.dashboardTransition(reduceMotion: reduceMotion))
            .animation(VaderMotion.surface, value: phaseTransitionID)
            .navigationTitle(NavigationSection.smartScan.title)
            // Every transition out of `.results` clears any in-flight Review
            // (e.g. Start Over → idle, Run → cleaning, an external reset).
            // Without this a stale `.review` value would re-emerge the next
            // time we land back on `.results`.
            .onChange(of: viewModel.phase) { _, newPhase in
                if case .results = newPhase {
                    // Preserve user's Review choice if any only while we
                    // remain in `.results` — re-entering results from a
                    // fresh scan should start on the dashboard.
                    return
                }
                review = nil
            }
    }

    /// Stable per-phase token so moving between scan phases crossfades
    /// instead of hard-cutting. Distinct phases map to distinct strings;
    /// associated values are intentionally ignored — only the phase identity
    /// drives the transition. The Review-vs-dashboard split within `.results`
    /// is deliberately not part of the token: Review swaps animate with the
    /// manager zoom motion inside `resultsContent`, and folding them into
    /// this identity would replace that with the phase crossfade.
    private var phaseTransitionID: String {
        switch viewModel.phase {
        case .idle:     return "idle"
        case .scanning: return "scanning"
        case .results:  return "results"
        case .cleaning: return "cleaning"
        case .done:     return "done"
        case .failed:   return "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            // Unreachable: ContentView shows the unified SectionIntroView
            // while the coordinator reports `.intro` (which `.idle` maps to),
            // so the detail view is never built in this phase. The arm stays
            // only to keep the switch exhaustive over `Phase`.
            EmptyView()
        case .scanning(let phase):
            // Key the progress view on the current stage so a stage change
            // rebuilds ScanningStatusView with the new phrase set — it shuffles
            // its phrases once at init, so a fresh identity is what swaps the
            // voice from the broad sweep to threats to the app check.
            SmartScanProgressState(
                label: phase,
                identifier: "smartScan.scanning",
                detail: viewModel.scanProgressDetail,
                phrases: ScanPhrases.smartScanStage(viewModel.currentStage)
            )
            .id(viewModel.currentStage)
        case .results(let result):
            resultsContent(result: result)
        case .cleaning:
            SmartScanProgressState(
                label: String(
                    localized: "Running…",
                    comment: "Progress label while the Smart Scan executes every selected module's action."
                ),
                identifier: "smartScan.cleaning"
            )
        case .done(let summary):
            SmartScanDoneState(
                summary: summary,
                onDone: { viewModel.reset() }
            )
        case .failed(let message):
            SmartScanFailedState(message: message) {
                viewModel.reset()
            }
        }
    }

    /// Within `.results`, route to the dashboard or to the active Review
    /// screen. Each Review pops back to the dashboard via `review = nil`.
    /// The two surfaces exchange inside a ZStack (a stable transition host)
    /// with the shared manager motion: the Review zooms up from the button
    /// that opened it over the receding dashboard, and zooms back into it on
    /// Back.
    @ViewBuilder
    private func resultsContent(result: SmartScanResult) -> some View {
        ZStack {
            if let review {
                reviewScreen(for: review, result: result)
                    .transition(VaderMotion.managerTransition(anchor: managerAnchor, reduceMotion: reduceMotion))
                    // Draw over the dashboard while the two overlap mid-swap.
                    .zIndex(1)
            } else {
                SmartScanResultsState(
                    viewModel: viewModel,
                    result: result,
                    onRequestReview: openReview,
                    onStartOver: { viewModel.reset() }
                )
                .transition(VaderMotion.dashboardTransition(reduceMotion: reduceMotion))
            }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame = $0 })
        .animation(VaderMotion.managerZoom, value: review)
    }

    /// Anchors the zoom to the button (or failing that, the click) being
    /// handled, then raises the module's Review screen.
    private func openReview(_ module: SmartScanModule) {
        managerAnchor = TriggerAnchor.resolve(in: paneFrame)
        review = module
    }

    /// The tile-specific Review screen for one Smart Scan module.
    @ViewBuilder
    private func reviewScreen(for review: SmartScanModule, result: SmartScanResult) -> some View {
        switch review {
        case .systemJunk:
            SmartScanJunkReview(
                viewModel: viewModel,
                result: result,
                onBack: { self.review = nil }
            )
        case .malware:
            SmartScanMalwareReview(
                viewModel: viewModel,
                result: result,
                onBack: { self.review = nil }
            )
        case .performance:
            SmartScanPerformanceReview(
                result: result,
                onBack: { self.review = nil },
                onOpenPerformance: onOpenPerformance
            )
        case .applications:
            SmartScanApplicationsReview(
                viewModel: viewModel,
                result: result,
                onBack: { self.review = nil }
            )
        case .myClutter:
            SmartScanMyClutterReview(
                viewModel: viewModel,
                result: result,
                onBack: { self.review = nil }
            )
        }
    }
}

#Preview("Results") {
    let vm = SmartScanViewModel(
        junkScanner: { _ in
            ScanResult(items: [
                ScannedFile(
                    url: URL(fileURLWithPath: "/Users/me/Library/Caches/big"),
                    size: 1_500_000_000,
                    lastAccessDate: nil,
                    lastModifiedDate: nil,
                    category: .userCache
                )
            ])
        },
        malwareInstalled: { true },
        malwareScanner: { _ in
            [
                MalwareThreat(
                    filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil.bin"),
                    threatName: "Eicar-Test-Signature"
                )
            ]
        },
        loginItemsLoader: {
            [LoginItem(id: "com.example.helper", name: "Example Helper", isEnabled: true)]
        },
        duplicatesScanner: { _ in [] },
        updatesChecker: { _ in [] },
        junkCleaner: { _ in 1_500_000_000 },
        threatRemover: { _ in [] },
        maintenanceRunner: { "Ran maintenance scripts." },
        updateOpener: { _ in },
        largeFileDeleter: { _ in [] }
    )
    return SmartScanView(
        viewModel: vm,
        onOpenPerformance: {}
    )
        .environment(SmartScanSettingsStore(defaults: UserDefaults(suiteName: "preview")!))
        .frame(width: 900, height: 600)
        .task { await vm.scan() }
}
