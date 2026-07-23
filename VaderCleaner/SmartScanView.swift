// SmartScanView.swift
// Smart Scan feature view — the default landing section. Walks the care-plan state machine: checklist scan → results feed → run → receipt, pushing per-finding Review screens over the feed.

import SwiftUI

/// Detail view shown when the user selects "Smart Scan" in the sidebar (the
/// default landing section). Drives `SmartScanViewModel`'s state machine, and
/// within `.results` either renders the care-plan feed or pushes a
/// finding-specific Review screen in place. The Review push is local state
/// (not a nested NavigationStack) so it never collides with the outer
/// section-slide transition in ContentView. The login-items Review uses
/// `onOpenPerformance` to jump to the standalone sidebar section.
struct SmartScanView: View {

    private var viewModel: SmartScanViewModel
    private let onOpenPerformance: () -> Void
    private let onOpenApplications: () -> Void

    /// The finding whose Review screen is currently up, or `nil` if the feed
    /// is visible. Local state because Review is a transient UI mode.
    @State private var review: CareFinding.Kind?
    /// The finding the retained Review screen is built for: the last one
    /// opened, so the (kept-alive, hidden) Review still has a concrete kind
    /// while the feed is showing. Reopening the same finding restores its
    /// built panes instantly; opening a different one swaps in a fresh screen.
    @State private var managerKind: CareFinding.Kind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the manager zoom anchors: the button that opened it.
    @State private var managerAnchor: UnitPoint = .center
    /// The transition host's frame in global space, for mapping the opening
    /// click to `managerAnchor`.
    @State private var paneFrame: CGRect = .zero
    /// The title-bar safe-area inset, claimed permanently by the results
    /// container and handed back to the feed as explicit padding so a Review
    /// Manager can extend up under the title bar.
    @State private var paneTopInset: CGFloat = 0

    /// The finding kinds whose Review screen exists. Kinds outside this set
    /// (today only the disk-space advisory) hide their card's Review
    /// affordance.
    static let reviewableKinds: Set<CareFinding.Kind> = [
        .junkCleanup, .threats, .appUpdates, .duplicates, .loginItems,
        .largeOldFiles, .unusedApps, .appLeftovers, .installers, .browserPrivacy,
        .similarImages, .downloads, .unsupportedApps, .extensions, .backgroundItems,
    ]

    init(
        viewModel: SmartScanViewModel,
        onOpenPerformance: @escaping () -> Void,
        onOpenApplications: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onOpenPerformance = onOpenPerformance
        self.onOpenApplications = onOpenApplications
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(phaseTransitionID)
            .transition(VaderMotion.dashboardTransition(reduceMotion: reduceMotion))
            .animation(VaderMotion.surface, value: phaseTransitionID)
            // The run-confirmation sheet floats over the whole feed (not inside
            // the transition host) so it can't be swept by the phase crossfade,
            // and only appears for a run that permanently deletes junk.
            .overlay {
                if viewModel.isConfirmingRun {
                    RunConfirmationSheet(
                        itemCount: viewModel.runnableFindingCount,
                        lines: viewModel.runActionSummary,
                        accent: SectionPresentation.for(.smartScan)?.accent ?? .vaderCrimson,
                        onConfirm: { Task { await viewModel.confirmRun() } },
                        onCancel: { viewModel.cancelRun() }
                    )
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(VaderMotion.surface, value: viewModel.isConfirmingRun)
            .navigationTitle(NavigationSection.smartScan.title)
            // Every transition out of `.results` clears any in-flight Review
            // so a stale value can't re-emerge on the next results landing.
            // Watches the cheap `phaseID` rather than the payload-carrying
            // `Phase` so no render drags the whole plan through `Equatable`.
            .onChange(of: viewModel.phaseID) { _, newPhaseID in
                if newPhaseID == "results" { return }
                review = nil
            }
            // Mirror the local Review navigation onto the view model so the
            // floating Run disc (hosted in a separate panel) can hide while a
            // Review Manager is open.
            .onChange(of: review) { _, newReview in
                viewModel.setReviewing(newReview != nil)
            }
    }

    /// Stable per-phase token so moving between scan phases crossfades
    /// instead of hard-cutting. Associated values are intentionally ignored —
    /// only the phase identity drives the transition.
    private var phaseTransitionID: String { viewModel.phaseID }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            // Unreachable: ContentView shows the unified SectionIntroView
            // while the coordinator reports `.intro` (which `.idle` maps to).
            // The arm stays only to keep the switch exhaustive over `Phase`.
            EmptyView()
        case .scanning:
            CareScanChecklistView(viewModel: viewModel)
        case .results:
            resultsContent
        case .running:
            SmartScanProgressState(
                label: String(
                    localized: "Fixing things up…",
                    comment: "Progress label while the Smart Scan runs every included finding's action."
                ),
                identifier: "smartScan.running"
            )
        case .done(let receipt):
            CareReceiptView(
                receipt: receipt,
                onDone: { viewModel.reset() }
            )
        case .failed(let message):
            SmartScanFailedState(message: message) {
                viewModel.reset()
            }
        }
    }

    /// Within `.results`, route to the feed or to the active Review screen.
    /// The two surfaces exchange inside `ManagerPresentationHost` (a stable
    /// transition host) with the shared manager motion; after Back the last
    /// finding's Review stays mounted (hidden), so reopening it restores its
    /// built panes instantly.
    private var resultsContent: some View {
        ManagerPresentationHost(
            isPresented: review != nil,
            anchor: managerAnchor,
            reduceMotion: reduceMotion,
            dashboardTopInset: paneTopInset
        ) {
            CarePlanFeedView(
                viewModel: viewModel,
                reviewableKinds: Self.reviewableKinds,
                onRequestReview: openReview,
                onStartOver: { viewModel.reset() }
            )
        } manager: {
            if let managerKind {
                reviewScreen(for: managerKind)
            }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame = $0 })
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { paneTopInset = $0 })
    }

    /// Anchors the zoom to the control being handled, then raises the
    /// finding's Review screen.
    private func openReview(_ kind: CareFinding.Kind) {
        guard Self.reviewableKinds.contains(kind) else { return }
        managerAnchor = TriggerAnchor.resolve(in: paneFrame)
        managerKind = kind
        review = kind
    }

    /// The finding-specific Review screen.
    @ViewBuilder
    private func reviewScreen(for kind: CareFinding.Kind) -> some View {
        switch kind {
        case .junkCleanup:
            SmartScanJunkReview(
                viewModel: viewModel,
                junkResult: viewModel.junkResult,
                store: viewModel.junkManagerStore,
                onBack: { review = nil }
            )
        case .threats:
            SmartScanMalwareReview(
                viewModel: viewModel,
                allThreats: threats,
                onBack: { review = nil }
            )
        case .appUpdates:
            SmartScanApplicationsReview(
                viewModel: viewModel,
                allUpdates: updates,
                onBack: { review = nil }
            )
        case .duplicates:
            SmartScanMyClutterReview(
                viewModel: viewModel,
                groups: duplicateGroups,
                onBack: { review = nil }
            )
        case .loginItems:
            SmartScanPerformanceReview(
                loginItems: loginItems,
                onBack: { review = nil },
                onOpenPerformance: onOpenPerformance
            )
        case .largeOldFiles:
            SmartScanLargeOldReview(
                viewModel: viewModel,
                files: largeOldFiles,
                onBack: { review = nil }
            )
        case .similarImages:
            SmartScanSimilarImagesReview(
                viewModel: viewModel,
                groups: similarImageGroups,
                onBack: { review = nil }
            )
        case .downloads:
            SmartScanDownloadsReview(
                viewModel: viewModel,
                items: downloadItems,
                onBack: { review = nil }
            )
        case .unsupportedApps:
            SmartScanUnsupportedAppsReview(
                viewModel: viewModel,
                apps: unsupportedApps,
                onBack: { review = nil }
            )
        case .extensions:
            SmartScanExtensionsReview(
                extensions: extensions,
                onBack: { review = nil },
                onOpenApplications: onOpenApplications
            )
        case .backgroundItems:
            SmartScanBackgroundItemsReview(
                agents: backgroundItems,
                onBack: { review = nil },
                onOpenPerformance: onOpenPerformance
            )
        case .unusedApps:
            SmartScanUnusedAppsReview(
                viewModel: viewModel,
                apps: unusedApps,
                onBack: { review = nil }
            )
        case .appLeftovers:
            SmartScanLeftoversReview(
                viewModel: viewModel,
                groups: leftoverGroups,
                onBack: { review = nil }
            )
        case .installers:
            SmartScanInstallersReview(
                viewModel: viewModel,
                installers: installers,
                onBack: { review = nil }
            )
        case .browserPrivacy:
            SmartScanBrowserPrivacyReview(
                viewModel: viewModel,
                summaries: browserPrivacySummaries,
                onBack: { review = nil }
            )
        case .lowDiskSpace, .maintenanceDue:
            // No Review — the disk advisory is informational and the tune-up
            // card is whole-tile work; both hide the affordance
            // (`reviewableKinds`), so this arm is unreachable.
            EmptyView()
        }
    }

    // MARK: - Payload slices for the Review screens

    private var threats: [MalwareThreat] {
        if case .threats(let threats)? = viewModel.currentPlan?.finding(.threats)?.payload { return threats }
        return []
    }

    private var updates: [UpdateInfo] {
        if case .appUpdates(let updates)? = viewModel.currentPlan?.finding(.appUpdates)?.payload { return updates }
        return []
    }

    private var duplicateGroups: [DuplicateGroup] {
        if case .duplicates(let groups)? = viewModel.currentPlan?.finding(.duplicates)?.payload { return groups }
        return []
    }

    private var loginItems: [LoginItem] {
        if case .loginItems(let items)? = viewModel.currentPlan?.finding(.loginItems)?.payload { return items }
        return []
    }

    private var largeOldFiles: [ScannedFile] {
        if case .largeOldFiles(let files)? = viewModel.currentPlan?.finding(.largeOldFiles)?.payload { return files }
        return []
    }

    private var similarImageGroups: [SimilarImageGroup] {
        if case .similarImages(let groups)? = viewModel.currentPlan?.finding(.similarImages)?.payload { return groups }
        return []
    }

    private var downloadItems: [DownloadItem] {
        if case .downloads(let items)? = viewModel.currentPlan?.finding(.downloads)?.payload { return items }
        return []
    }

    private var unsupportedApps: [UnsupportedApp] {
        if case .unsupportedApps(let apps)? = viewModel.currentPlan?.finding(.unsupportedApps)?.payload { return apps }
        return []
    }

    private var extensions: [ExtensionItem] {
        if case .extensions(let items)? = viewModel.currentPlan?.finding(.extensions)?.payload { return items }
        return []
    }

    private var backgroundItems: [LaunchAgent] {
        if case .backgroundItems(let agents)? = viewModel.currentPlan?.finding(.backgroundItems)?.payload { return agents }
        return []
    }

    private var unusedApps: [UnusedApp] {
        if case .unusedApps(let apps)? = viewModel.currentPlan?.finding(.unusedApps)?.payload { return apps }
        return []
    }

    private var leftoverGroups: [LeftoverGroup] {
        if case .appLeftovers(let groups)? = viewModel.currentPlan?.finding(.appLeftovers)?.payload { return groups }
        return []
    }

    private var installers: [InstallationFile] {
        if case .installers(let files)? = viewModel.currentPlan?.finding(.installers)?.payload { return files }
        return []
    }

    private var browserPrivacySummaries: [BrowserPrivacySummary] {
        if case .browserPrivacy(let summaries)? = viewModel.currentPlan?.finding(.browserPrivacy)?.payload { return summaries }
        return []
    }
}

#Preview("Results") {
    let plan = CarePlan(
        findings: [
            CareFinding(kind: .junkCleanup, payload: .junk(ScanResult(items: [
                ScannedFile(
                    url: URL(fileURLWithPath: "/Users/me/Library/Caches/big"),
                    size: 1_500_000_000,
                    lastAccessDate: nil,
                    lastModifiedDate: nil,
                    category: .userCache
                )
            ]))),
            CareFinding(kind: .threats, payload: .threats([
                MalwareThreat(
                    filePath: URL(fileURLWithPath: "/Users/me/Downloads/evil.bin"),
                    threatName: "Eicar-Test-Signature"
                )
            ])),
            CareFinding(kind: .loginItems, payload: .loginItems([
                LoginItem(id: "com.example.helper", name: "Example Helper", isEnabled: true)
            ])),
        ],
        health: nil,
        unitOutcomes: [.systemJunk: .completed, .malware: .completed, .loginItems: .completed],
        startedAt: Date(),
        finishedAt: Date()
    )
    let vm = SmartScanViewModel(
        scanEngine: { _, _ in plan }
    )
    return SmartScanView(
        viewModel: vm,
        onOpenPerformance: {}
    )
        .environment(SmartScanSettingsStore(defaults: UserDefaults(suiteName: "preview")!))
        .frame(width: 900, height: 600)
        .task { await vm.scan() }
}
