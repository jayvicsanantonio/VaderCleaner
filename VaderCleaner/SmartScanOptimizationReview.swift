// SmartScanOptimizationReview.swift
// Read-only Performance/Optimization Review for Smart Scan — explainer plus an "Open Optimization" jump-link.

import SwiftUI

/// Read-only summary for the Performance / Optimization Review. The
/// actionable work — running the maintenance scripts — is the *whole*
/// tile, not a per-item selection; the login-item list shown here is
/// informational. An "Open Optimization" link lets the user jump to the
/// standalone screen to manage login items / launch agents / RAM in detail.
struct SmartScanOptimizationReview: View {
    let result: SmartScanResult
    /// Whether the maintenance scripts can run — false on macOS 26+, where
    /// `periodic` was removed. Drives the explainer wording.
    var maintenanceScriptsAvailable: Bool = true
    let onBack: () -> Void
    let onOpenOptimization: () -> Void

    private var explainer: String {
        if maintenanceScriptsAvailable {
            return String(
                localized: "Run carries out macOS's built-in maintenance scripts — the daily, weekly, and monthly cleanup routines.",
                comment: "Explainer at the top of the Smart Scan Performance Review screen."
            )
        }
        return String(
            localized: "macOS's maintenance scripts aren't available on this version of macOS, so there's nothing to run here. The login items below are shown for review.",
            comment: "Explainer shown when periodic maintenance scripts are unavailable (macOS 26+)."
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SmartScanReviewHeader(
                title: String(
                    localized: "Performance Manager",
                    comment: "Title on the Smart Scan Optimization Review screen."
                ),
                onBack: onBack
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(explainer)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if !result.optimizationItems.isEmpty {
                        Text(String(
                            localized: "Login Items",
                            comment: "Section heading inside the Smart Scan Performance Review screen for the read-only login-item list."
                        ))
                            .font(.headline)
                        ForEach(result.optimizationItems, id: \.id) { item in
                            HStack {
                                Image(systemName: "power")
                                    .foregroundStyle(.orange)
                                Text(item.name)
                                Spacer()
                                Text(item.isEnabled
                                    ? String(
                                        localized: "Enabled",
                                        comment: "Status label for a login item enabled at boot."
                                    )
                                    : String(
                                        localized: "Disabled",
                                        comment: "Status label for a login item disabled at boot."
                                    ))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Button(
                        String(
                            localized: "Open Optimization",
                            comment: "Button on the Smart Scan Performance Review that jumps to the standalone Optimization screen."
                        ),
                        action: onOpenOptimization
                    )
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("smartScan.review.openOptimization")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("smartScan.review.optimization")
    }
}
