// SmartScanView.swift
// Smart Scan feature view — the default landing section. Walks the scan → results → clean → done state machine of SmartScanViewModel, surfacing one summary card per orchestrated sub-module.

import SwiftUI

/// Detail view shown when the user selects "Smart Scan" in the sidebar (the
/// default landing section). Drives `SmartScanViewModel`'s state machine and
/// routes each dashboard card's "Review" action back to the sidebar via the
/// per-section callbacks so the user lands on that section's full screen.
struct SmartScanView: View {

    @ObservedObject private var viewModel: SmartScanViewModel
    private let onReviewSystemJunk: () -> Void
    private let onReviewMalware: () -> Void
    private let onReviewOptimization: () -> Void

    init(
        viewModel: SmartScanViewModel,
        onReviewSystemJunk: @escaping () -> Void,
        onReviewMalware: @escaping () -> Void,
        onReviewOptimization: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onReviewSystemJunk = onReviewSystemJunk
        self.onReviewMalware = onReviewMalware
        self.onReviewOptimization = onReviewOptimization
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.smartScan.title)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            SmartScanIdleState(onScan: { Task { await viewModel.scan() } })
        case .scanning(let phase):
            SmartScanProgressState(
                label: phase,
                identifier: "smartScan.scanning"
            )
        case .results(let result):
            SmartScanResultsState(
                result: result,
                onClean: { Task { await viewModel.clean() } },
                onReviewSystemJunk: onReviewSystemJunk,
                onReviewMalware: onReviewMalware,
                onReviewOptimization: onReviewOptimization,
                onStartOver: { viewModel.reset() }
            )
        case .cleaning:
            SmartScanProgressState(
                label: String(
                    localized: "Cleaning up…",
                    comment: "Progress label while the Smart Scan removes junk and threats."
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
}

#Preview("Results") {
    let vm = SmartScanViewModel(
        junkScanner: {
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
        malwareScanner: {
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
        junkCleaner: { _ in 1_500_000_000 },
        threatRemover: { _ in [] }
    )
    return SmartScanView(
        viewModel: vm,
        onReviewSystemJunk: {},
        onReviewMalware: {},
        onReviewOptimization: {}
    )
        .frame(width: 900, height: 600)
        .task { await vm.scan() }
}
