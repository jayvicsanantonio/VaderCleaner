// MyClutterView.swift
// My Clutter section detail: switches between the scanning state, the four-card results dashboard, and the My Clutter Manager review screen (deep-linked to the tapped card's category).

import SwiftUI

/// Detail view for the My Clutter section. Owns the transient "which review is
/// open" navigation state and renders the dashboard, the review screen, or the
/// scan/empty states based on the view-model's phase.
struct MyClutterView: View {
    @Bindable var viewModel: MyClutterViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent = NavigationSection.largeOldFiles.theme.accent

    /// Which review screen is up, or `nil` for the dashboard.
    @State private var review: ReviewTarget?
    /// Where the manager zoom anchors: the button that opened it, resolved
    /// by `openReview`. Also the point Back zooms the manager back into.
    @State private var managerAnchor: UnitPoint = .center
    /// The transition host's frame in global space, for mapping the opening
    /// click to `managerAnchor`.
    @State private var paneFrame: CGRect = .zero
    /// The title-bar safe-area inset the transition host permanently claims;
    /// handed back to the dashboard as top padding so only the manager
    /// extends under the title bar.
    @State private var paneTopInset: CGFloat = 0

    /// A review destination: one card's category, or every category at once.
    enum ReviewTarget: Equatable {
        case duplicates
        case similar
        case largeOld
        case downloads
        case all
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.largeOldFiles.title)
            .environment(\.sectionAccent, accent)
            .onChange(of: viewModel.phase) { _, newPhase in
                // Leaving results always drops any open review so a stale one
                // never re-emerges on the next scan.
                if newPhase != .results { review = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            // ContentView shows the shared intro while idle; never built here.
            EmptyView()
        case .scanning:
            LargeOldFilesProgressState(
                label: String(localized: "Scanning…", comment: "My Clutter scanning status."),
                identifier: "myClutter.scanning",
                detail: ScanProgressFormatting.itemsScanned(viewModel.scannedItemCount),
                phrases: ScanPhrases.scanning(for: .largeOldFiles)
            )
        case .empty:
            LargeOldFilesEmptyState(
                onScanAgain: viewModel.scanAgain,
                hasFullDiskAccess: appState.hasFullDiskAccess,
                onRefreshAccess: { appState.refresh() }
            )
        case .failed(let message):
            LargeOldFilesFailedState(stage: .scanning, message: message, onTryAgain: viewModel.scanAgain)
        case .results:
            // The dashboard and the review manager exchange inside a ZStack
            // (a stable transition host) with the shared manager motion: the
            // manager zooms up from the button that opened it over the
            // receding dashboard, and zooms back into it on Back.
            ZStack {
                if let review {
                    MyClutterManagerView(
                        viewModel: viewModel,
                        initialCategory: Self.category(for: review),
                        onBack: { self.review = nil }
                    )
                    .transition(VaderMotion.managerTransition(anchor: managerAnchor, reduceMotion: reduceMotion))
                    // Draw over the dashboard while the two overlap mid-swap.
                    .zIndex(1)
                } else {
                    dashboard
                        // The dashboard keeps its usual place below the title
                        // bar: the host ZStack claims that inset permanently,
                        // so it is handed back here as explicit padding.
                        .padding(.top, paneTopInset)
                        .transition(VaderMotion.dashboardTransition(reduceMotion: reduceMotion))
                }
            }
            // Claim the title-bar safe area on this stable container, never
            // on a transitioning branch: safe-area changes anywhere inside a
            // freshly inserted transition subtree are deferred until its
            // spring fully settles, which read as the manager stuck below a
            // title-bar-height gap for a beat after opening.
            .ignoresSafeArea(.container, edges: .top)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame = $0 })
            .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { paneTopInset = $0 })
            .animation(VaderMotion.managerZoom, value: review)
        }
    }

    /// Anchors the zoom to the button (or failing that, the click) being
    /// handled, then raises the review.
    private func openReview(_ target: ReviewTarget) {
        managerAnchor = TriggerAnchor.resolve(in: paneFrame)
        review = target
    }

    private var dashboard: some View {
        MyClutterDashboardView(
            viewModel: viewModel,
            accent: accent,
            onReviewAll: { openReview(.all) },
            onReviewDuplicates: { openReview(.duplicates) },
            onReviewSimilar: { openReview(.similar) },
            onReviewLargeOld: { openReview(.largeOld) },
            onReviewDownloads: { openReview(.downloads) },
            onStartOver: viewModel.scanAgain
        )
    }

    /// Maps a dashboard Review target onto the manager's initially-selected
    /// category. "Review All Files" opens on the first category; every category
    /// is reachable from the manager's left pane regardless.
    private static func category(for target: ReviewTarget) -> MyClutterCategory {
        switch target {
        case .duplicates: return .duplicates
        case .similar: return .similar
        case .largeOld, .all: return .largeOld
        case .downloads: return .downloads
        }
    }
}
