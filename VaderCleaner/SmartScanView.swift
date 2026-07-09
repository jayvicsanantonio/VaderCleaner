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
    /// The title-bar safe-area inset, claimed permanently by the results
    /// container and handed back to the dashboard as explicit padding so a
    /// Review Manager can extend up under the title bar (a thin, even top
    /// margin) while the dashboard keeps its usual place below it.
    @State private var paneTopInset: CGFloat = 0
    /// Prebuilt, cached model behind the System Junk Review so its three panes
    /// paint instantly (cheap shell) and each category's folder tree loads
    /// lazily — warmed in the background the moment a scan lands on `.results`.
    /// The same store the standalone Cleanup Manager uses.
    @State private var junkManagerStore = CleanupManagerStore()

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
                if case .results(let result) = newPhase {
                    // Warm the Cleanup Manager's model in the background so
                    // opening the System Junk Review paints its panes instantly.
                    junkManagerStore.load(result: result.junkResult)
                    // Preserve user's Review choice if any only while we
                    // remain in `.results` — re-entering results from a
                    // fresh scan should start on the dashboard.
                    return
                }
                review = nil
            }
            // Mirror the local Review navigation onto the view model so the
            // floating Run disc (hosted in a separate panel) can hide while a
            // Review Manager is open.
            .onChange(of: review) { _, newReview in
                viewModel.setReviewing(newReview != nil)
            }
            .task {
                // Catch the case where results are already present on first
                // appear (e.g. returning to the section), so the Review's panes
                // are still warm.
                if case .results(let result) = viewModel.phase {
                    junkManagerStore.load(result: result.junkResult)
                }
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
        case .scanning:
            // The staged scanning screen: one module heroes at a time while
            // the others fill in with result summaries as their sub-scans
            // are collected.
            SmartScanScanningView(viewModel: viewModel)
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
                // The dashboard keeps its usual place below the title bar: the
                // host ZStack claims that inset permanently, so it is handed
                // back here as explicit padding.
                .padding(.top, paneTopInset)
                .transition(VaderMotion.dashboardTransition(reduceMotion: reduceMotion))
            }
        }
        // Claim the title-bar safe area on this stable container, never on a
        // transitioning branch: safe-area changes anywhere inside a freshly
        // inserted transition subtree are deferred until its spring fully
        // settles, which read as the Review Manager stuck below a title-bar-
        // height gap for a beat after opening.
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame = $0 })
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { paneTopInset = $0 })
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
                store: junkManagerStore,
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
