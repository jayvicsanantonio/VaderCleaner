// PrivacyView.swift
// Privacy feature view — orchestrates privacy scan phases, destructive confirmation, and clear / re-scan actions.

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

    init(viewModel: PrivacyViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.privacy.title)
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
            PrivacyProgressState(label: "Scanning…", identifier: "privacy.scanning")
        case .preview:
            PrivacyPreviewContent(
                browsers: viewModel.detectedBrowsers,
                totalSelectedSize: viewModel.totalSelectedSize,
                isClearRecentsChecked: viewModel.isClearRecentsChecked,
                canClear: viewModel.totalSelectedSize != 0 || viewModel.isClearRecentsChecked,
                sizeOnDisk: { viewModel.sizeOnDisk(for: $0) },
                categorySize: { viewModel.size(for: $0, category: $1) },
                isCategoryActionable: { viewModel.isCategoryActionable(browser: $0, category: $1) },
                isCategoryChecked: { viewModel.isChecked(browser: $0, category: $1) },
                onToggleCategory: { viewModel.toggle(browser: $0, category: $1) },
                onToggleClearRecents: { viewModel.toggleClearRecents() },
                onRescan: viewModel.scanAgain,
                onClear: { showClearConfirmation = true }
            )
        case .clearing:
            PrivacyProgressState(label: "Clearing…", identifier: "privacy.clearing")
        case .complete(let bytes):
            PrivacyCompleteState(bytesFreed: bytes, onScanAgain: viewModel.scanAgain)
        case .failed(let stage, let message):
            PrivacyFailedState(stage: stage, message: message, onTryAgain: viewModel.scanAgain)
        }
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
