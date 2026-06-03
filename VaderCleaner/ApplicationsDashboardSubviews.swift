// ApplicationsDashboardSubviews.swift
// Post-scan dashboard for the Applications section — the "N apps found" header, the summary card grid, and the progress / failed states.

import SwiftUI

// MARK: - Dashboard

/// The Applications landing surface after a scan: a headline count, a "Manage
/// My Applications" affordance, and the summary cards in an adaptive grid —
/// mirroring the Optimization dashboard's card layout.
struct ApplicationsDashboardView: View {
    let result: ApplicationsScanResult
    let onOpenUpdates: () -> Void
    let onOpenManage: () -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            header
            grid
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("applications.dashboard")
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text(installedCountText)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("applications.installedCount")

            HStack(spacing: 12) {
                Button(action: onOpenManage) {
                    Text(String(
                        localized: "Manage My Applications",
                        comment: "Button that opens the full installed-apps management (uninstaller) list."
                    ))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("applications.manageMyApplications")

                Button(action: onRescan) {
                    Text(String(
                        localized: "Rescan",
                        comment: "Button that re-runs the Applications scan."
                    ))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("applications.rescan")
            }
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260), spacing: 16)],
            alignment: .leading,
            spacing: 16
        ) {
            ApplicationsCard(
                title: updatesTitle,
                detail: updatesDetail,
                icon: "arrow.triangle.2.circlepath",
                actionLabel: String(
                    localized: "Review",
                    comment: "Applications Updates card action that opens the update list."
                ),
                identifier: "applications.card.updates",
                action: onOpenUpdates
            )
            ApplicationsCard(
                title: String(
                    localized: "Manage Applications",
                    comment: "Applications management card title."
                ),
                detail: manageDetail,
                icon: "square.grid.2x2",
                actionLabel: String(
                    localized: "Manage",
                    comment: "Applications management card action."
                ),
                identifier: "applications.card.manage",
                action: onOpenManage
            )
        }
    }

    // MARK: Copy

    private var installedCountText: String {
        let format = String(
            localized: "We've found %lld apps on your Mac.",
            comment: "Applications dashboard headline; %lld is the installed-app count."
        )
        return String.localizedStringWithFormat(format, Int64(result.installedCount))
    }

    private var updatesTitle: String {
        if result.updatesCount == 0 {
            return String(
                localized: "No Updates Available",
                comment: "Applications Updates card title when every app is current."
            )
        }
        let format = String(
            localized: "%lld Application Updates Available",
            comment: "Applications Updates card title; %lld is the available-update count."
        )
        return String.localizedStringWithFormat(format, Int64(result.updatesCount))
    }

    private var updatesDetail: String {
        if result.updatesCount == 0 {
            return String(
                localized: "All your apps are running the latest version.",
                comment: "Applications Updates card detail when no updates are available."
            )
        }
        return String(
            localized: "Update your software to keep up with the latest features and compatibility improvements.",
            comment: "Applications Updates card detail when updates are available."
        )
    }

    private var manageDetail: String {
        let format = String(
            localized: "Browse all %lld installed apps and remove the ones you no longer need, along with their leftover files.",
            comment: "Applications management card detail; %lld is the installed-app count."
        )
        return String.localizedStringWithFormat(format, Int64(result.installedCount))
    }
}

/// A single Applications summary card. Uses the same glass surface and corner
/// radius as the Optimization / Smart Scan dashboards so the app's card
/// surfaces stay consistent.
struct ApplicationsCard: View {
    let title: String
    let detail: String
    let icon: String
    let actionLabel: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack {
                Spacer()
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Progress

/// Centered spinner shown while the Applications scan runs.
struct ApplicationsProgressState: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(String(
                localized: "Scanning your applications…",
                comment: "Progress label shown while the Applications scan runs."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("applications.loading")
    }
}

// MARK: - Failed

/// Error state for a failed Applications scan, with a retry that re-runs it.
struct ApplicationsFailedState: View {
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(String(
                localized: "Couldn't scan your applications",
                comment: "Title shown on the Applications scan failure screen."
            ))
            .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("applications.errorMessage")
            Button(String(
                localized: "Try Again",
                comment: "Retry button on the Applications scan failure screen."
            ), action: onTryAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("applications.tryAgain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
