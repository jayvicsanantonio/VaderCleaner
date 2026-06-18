// PrivacyView.swift
// Privacy feature view — orchestrates privacy scan phases, destructive confirmation, and clear / re-scan actions.

import AppKit
import SwiftUI

/// Detail view shown when the user selects "Privacy" in the sidebar.
/// The parent owns feature state and destructive-action coordination while
/// dedicated subviews render each phase and preview row.
///
/// The `.idle` phase is not rendered here: ContentView shows the unified
/// `SectionIntroView` plus the floating Scan button while the coordinator
/// reports `.intro`, so the detail view is only built once a scan has started.
struct PrivacyView: View {

    private var viewModel: PrivacyViewModel
    @State private var showClearConfirmation = false

    /// Which screen the preview surface is showing — the dashboard grid or
    /// the Privacy Manager catalog. Owned here (mirroring
    /// `ApplicationsView.detail`) and reset whenever the phase leaves
    /// `.preview` so a fresh scan always lands on the dashboard.
    @State private var previewDetail: PreviewDetail = .dashboard

    /// Which catalog pane to show. Owned here (mirroring
    /// `OptimizationView.catalogPane`) so a card's Review button can open the
    /// catalog on its matching category pane.
    @State private var catalogPane: PrivacyDataCatalogView.Pane = .category(.history)

    private enum PreviewDetail: Equatable {
        case dashboard
        case catalog
    }

    /// Shared icon cache so the dashboard's browser strip and the catalog's
    /// rows show each browser's real app icon. Pre-loaded off the main
    /// thread once the detected browsers land.
    @State private var iconCache = AppIconCache()

    /// Resolved `.app` bundle URL per detected browser, looked up once per
    /// scan via Launch Services rather than per-row inside SwiftUI `body`.
    @State private var browserBundleURLs: [Browser: URL] = [:]

    init(viewModel: PrivacyViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.privacy.title)
            .onChange(of: viewModel.phase) { _, newPhase in
                if newPhase != .preview {
                    previewDetail = .dashboard
                }
            }
            .task(id: viewModel.detectedBrowsers) {
                // Resolve each detected browser's bundle URL once per scan
                // (Launch Services lookup), then warm the icon cache off the
                // main thread so rows render real icons without synchronous
                // NSWorkspace calls in `body`.
                var urls: [Browser: URL] = [:]
                for browser in viewModel.detectedBrowsers {
                    urls[browser] = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: browser.bundleIdentifier)
                }
                browserBundleURLs = urls
                await iconCache.preloadIcons(for: Array(urls.values))
            }
            .alert(clearConfirmationTitle, isPresented: $showClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    Task { await viewModel.clear() }
                }
            } message: {
                Text(clearConfirmationMessage)
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
            PrivacyProgressState(
                label: "Scanning…",
                identifier: "privacy.scanning",
                detail: ScanProgressFormatting.itemsScanned(viewModel.scannedItemCount),
                phrases: ScanPhrases.scanning(for: .privacy)
            )
        case .preview:
            previewContent
        case .clearing:
            PrivacyProgressState(label: "Clearing…", identifier: "privacy.clearing")
        case .complete(let bytes):
            PrivacyCompleteState(bytesFreed: bytes, onScanAgain: viewModel.scanAgain)
        case .failed(let stage, let message):
            PrivacyFailedState(stage: stage, message: message, onTryAgain: viewModel.scanAgain)
        }
    }

    /// The `.preview` surface: the dashboard grid, or the Privacy Manager
    /// catalog that both "View All Data" and every card's Review button open.
    /// The catalog carries the pinned Clear bar, so the destructive action
    /// only appears once the user is looking at the selection it acts on.
    @ViewBuilder
    private var previewContent: some View {
        switch previewDetail {
        case .dashboard:
            // The dashboard divides the pane height into a hero column and a
            // grid of equal-height tiles, so it fills the detail area without a
            // scroll view.
            PrivacyDashboardView(
                browserCount: viewModel.detectedBrowsers.count,
                totalFoundSize: viewModel.totalFoundSize,
                categories: viewModel.dashboardCategories(),
                categorySize: { viewModel.size(forCategory: $0) },
                onReviewCategory: { openCatalog(on: .category($0)) },
                onReviewSystem: { openCatalog(on: .system) },
                onViewAllData: { openCatalog(on: .category(.history)) },
                onRescan: viewModel.scanAgain
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .catalog:
            PrivacyDataCatalogView(
                pane: $catalogPane,
                browsers: viewModel.detectedBrowsers,
                iconCache: iconCache,
                bundleURL: { browserBundleURLs[$0] },
                categorySize: { viewModel.size(for: $0, category: $1) },
                isCategoryActionable: { viewModel.isCategoryActionable(browser: $0, category: $1) },
                isCategoryChecked: { viewModel.isChecked(browser: $0, category: $1) },
                onToggleCategory: { viewModel.toggle(browser: $0, category: $1) },
                isClearRecentsChecked: viewModel.isClearRecentsChecked,
                onToggleClearRecents: { viewModel.toggleClearRecents() },
                totalSelectedSize: viewModel.totalSelectedSize,
                canClear: viewModel.totalSelectedSize != 0 || viewModel.isClearRecentsChecked,
                onClear: { showClearConfirmation = true },
                onBack: { previewDetail = .dashboard }
            )
        }
    }

    /// Open the Privacy Manager catalog on `pane` — the shared destination
    /// for View All Data and every card's Review button, which differ only
    /// in which pane they land on.
    private func openCatalog(on pane: PrivacyDataCatalogView.Pane) {
        catalogPane = pane
        previewDetail = .catalog
    }

    private var clearConfirmationTitle: String {
        String(
            localized: "Clear selected privacy data?",
            comment: "Alert title asking the user to confirm clearing selected privacy data."
        )
    }

    private var clearConfirmationMessage: String {
        if viewModel.isClearRecentsChecked {
            return String(
                localized: "This permanently removes the selected browser data and the system Recent Items list. Browsers will recreate the storage on next launch but the data won't be recoverable.",
                comment: "Alert message shown when clearing selected browser data and system Recent Items."
            )
        }
        return String(
            localized: "This permanently removes the selected browser data. Browsers will recreate the storage on next launch but the data won't be recoverable.",
            comment: "Alert message shown when clearing selected browser data only."
        )
    }
}

#Preview("Idle") {
    PrivacyView(viewModel: PrivacyViewModel(
        detector: { [] },
        sizer: { _, _ in 0 },
        pathsFor: { _, _ in [] },
        clearer: { _, _ in },
        clearRecentFiles: { }
    ))
    .frame(width: 700, height: 480)
    .environment(AppState(checker: { true }))
}
