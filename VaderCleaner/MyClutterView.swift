// MyClutterView.swift
// My Clutter section detail: switches between the scanning state, the four-card results dashboard, and the My Clutter Manager review screen (deep-linked to the tapped card's category).

import SwiftUI

/// Detail view for the My Clutter section. Owns the transient "which review is
/// open" navigation state and renders the dashboard, the review screen, or the
/// scan/empty states based on the view-model's phase.
struct MyClutterView: View {
    @Bindable var viewModel: MyClutterViewModel
    @Environment(AppState.self) private var appState

    private let accent = NavigationSection.largeOldFiles.theme.accent

    /// Which review screen is up, or `nil` for the dashboard.
    @State private var review: ReviewTarget?

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
            if let review {
                MyClutterManagerView(
                    viewModel: viewModel,
                    initialCategory: Self.category(for: review),
                    onBack: { self.review = nil }
                )
            } else {
                dashboard
            }
        }
    }

    private var dashboard: some View {
        MyClutterDashboardView(
            viewModel: viewModel,
            accent: accent,
            onReviewAll: { review = .all },
            onReviewDuplicates: { review = .duplicates },
            onReviewSimilar: { review = .similar },
            onReviewLargeOld: { review = .largeOld },
            onReviewDownloads: { review = .downloads },
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
