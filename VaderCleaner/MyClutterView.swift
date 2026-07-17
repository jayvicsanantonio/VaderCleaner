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
    /// The target the retained manager is built with: the last one opened, so
    /// the (kept-alive, hidden) manager still has a concrete category while
    /// the dashboard is showing. Updated on every open.
    @State private var managerTarget: ReviewTarget = .all
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
            // The dashboard and the review manager exchange inside
            // `ManagerPresentationHost` (a stable transition host) with the
            // shared manager motion: the manager zooms up from the button that
            // opened it over the receding dashboard, and zooms back into it on
            // Back — after which it stays mounted (hidden), so reopening
            // restores its built caches and panes instantly.
            ManagerPresentationHost(
                isPresented: review != nil,
                anchor: managerAnchor,
                reduceMotion: reduceMotion,
                dashboardTopInset: paneTopInset
            ) {
                dashboard
            } manager: {
                MyClutterManagerView(
                    viewModel: viewModel,
                    initialCategory: Self.category(for: managerTarget),
                    isPresented: review != nil,
                    onBack: { self.review = nil }
                )
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame = $0 })
            .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { paneTopInset = $0 })
        }
    }

    /// Anchors the zoom to the button (or failing that, the click) being
    /// handled, then raises the review.
    private func openReview(_ target: ReviewTarget) {
        managerAnchor = TriggerAnchor.resolve(in: paneFrame)
        managerTarget = target
        review = target
    }

    private var dashboard: some View {
        MyClutterDashboardView(
            viewModel: viewModel,
            accent: accent,
            // "Review All Files" browses everything with nothing checked;
            // each card's Review pre-selects only that card's group so the
            // manager opens matching the tile the user tapped.
            onReviewAll: { viewModel.clearSelection(); openReview(.all) },
            onReviewDuplicates: { viewModel.selectOnly(category: .duplicates); openReview(.duplicates) },
            onReviewSimilar: { viewModel.selectOnly(category: .similar); openReview(.similar) },
            onReviewLargeOld: { viewModel.selectOnly(category: .largeOld); openReview(.largeOld) },
            onReviewDownloads: { viewModel.selectOnly(category: .downloads); openReview(.downloads) },
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
