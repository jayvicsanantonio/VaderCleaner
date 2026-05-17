// AppUpdaterView.swift
// App Updater feature view — orchestrates the check-for-updates flow, renders the merged App Store + Sparkle update list, and routes per-app and "Update All" actions through the view-model.

import SwiftUI

struct AppUpdaterView: View {

    @ObservedObject private var viewModel: AppUpdaterViewModel

    init(viewModel: AppUpdaterViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.appUpdater.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await viewModel.checkForUpdates() } }) {
                        Label(String(
                            localized: "Check for Updates",
                            comment: "Toolbar button on the App Updater that re-checks for updates."
                        ), systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.phase == .checking)
                    .accessibilityIdentifier("appUpdater.check")
                }
            }
            .task {
                if viewModel.phase == .idle {
                    await viewModel.checkForUpdates()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .checking:
            AppUpdaterProgressState()
        case .ready:
            if viewModel.availableUpdates.isEmpty {
                AppUpdaterUpToDateState()
            } else {
                AppUpdaterListState(
                    updates: viewModel.availableUpdates,
                    onUpdate: { info in
                        Task { await viewModel.update(info) }
                    },
                    onUpdateAll: { Task { await viewModel.updateAll() } }
                )
            }
        case .failed(let message):
            AppUpdaterFailedState(
                message: message,
                onTryAgain: { Task { await viewModel.checkForUpdates() } }
            )
        }
    }
}

// MARK: - Subviews

private struct AppUpdaterProgressState: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(String(
                localized: "Checking for updates…",
                comment: "Progress label shown while the App Updater is fetching versions."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("appUpdater.loading")
    }
}

private struct AppUpdaterUpToDateState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(String(
                localized: "All apps are up to date",
                comment: "Empty state shown on the App Updater when no updates are available."
            ))
                .font(.title3.weight(.semibold))
            Text(String(
                localized: "We didn't find any newer versions for your installed apps.",
                comment: "Detail shown on the App Updater empty state."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("appUpdater.upToDate")
    }
}

private struct AppUpdaterListState: View {
    let updates: [UpdateInfo]
    let onUpdate: (UpdateInfo) -> Void
    let onUpdateAll: () -> Void

    /// Above this many pending updates, "Update All" asks for
    /// confirmation first — each entry opens an App Store page or a
    /// browser download, and firing a dozen-plus external actions at
    /// once with no warning is a jarring experience.
    private static let bulkConfirmationThreshold = 10
    @State private var showBulkConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(updates) { info in
                    AppUpdaterRow(info: info, onUpdate: { onUpdate(info) })
                        .accessibilityIdentifier("appUpdater.row.\(info.bundleID)")
                }
            }
            .listStyle(.inset)
            Divider()
            HStack(spacing: 12) {
                Text(updatesCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(
                    localized: "Update All",
                    comment: "Footer button on the App Updater that opens every available update."
                ), action: updateAllTapped)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("appUpdater.updateAll")
            }
            .padding(16)
        }
        .alert(
            String(
                localized: "Open all updates?",
                comment: "Title of the confirmation shown before opening many updates at once."
            ),
            isPresented: $showBulkConfirmation
        ) {
            Button(String(localized: "Cancel"), role: .cancel) { }
            Button(String(
                localized: "Open All",
                comment: "Confirm button on the App Updater bulk-update confirmation."
            )) {
                onUpdateAll()
            }
        } message: {
            Text(bulkConfirmationMessage)
        }
    }

    private func updateAllTapped() {
        if updates.count > Self.bulkConfirmationThreshold {
            showBulkConfirmation = true
        } else {
            onUpdateAll()
        }
    }

    private var bulkConfirmationMessage: String {
        let format = String(
            localized: "This opens %lld update pages or downloads at once.",
            comment: "Body of the App Updater bulk-update confirmation."
        )
        return String.localizedStringWithFormat(format, Int64(updates.count))
    }

    private var updatesCountText: String {
        if updates.count == 1 {
            return String(
                localized: "1 update available",
                comment: "Footer label on the App Updater when exactly one update is pending."
            )
        }
        let format = String(
            localized: "%lld updates available",
            comment: "Footer label on the App Updater showing how many updates are pending."
        )
        return String.localizedStringWithFormat(format, Int64(updates.count))
    }
}

private struct AppUpdaterRow: View {
    let info: UpdateInfo
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sourceIcon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.appName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(versionTransitionText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(sourceBadge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            Spacer()
            Button(String(
                localized: "Update",
                comment: "Per-row action button on the App Updater list."
            ), action: onUpdate)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("appUpdater.update.\(info.bundleID)")
        }
        .padding(.vertical, 4)
    }

    private var versionTransitionText: String {
        let format = String(
            localized: "%@ → %@",
            comment: "Version transition label on App Updater rows (installed → latest)."
        )
        return String.localizedStringWithFormat(
            format,
            info.installedVersion,
            info.latestVersion
        )
    }

    private var sourceBadge: String {
        switch info.source {
        case .appStore:
            return String(
                localized: "App Store",
                comment: "Badge text shown on App Updater rows sourced from the Mac App Store."
            )
        case .sparkle:
            return String(
                localized: "Sparkle",
                comment: "Badge text shown on App Updater rows sourced from a Sparkle appcast."
            )
        }
    }

    private var sourceIcon: String {
        switch info.source {
        case .appStore: return "bag"
        case .sparkle:  return "sparkles"
        }
    }
}

private struct AppUpdaterFailedState: View {
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(String(
                localized: "Couldn't check for updates",
                comment: "Title shown on the App Updater failure screen."
            ))
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("appUpdater.errorMessage")
            Button(String(
                localized: "Try Again",
                comment: "Retry button on the App Updater failure screen."
            ), action: onTryAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("appUpdater.tryAgain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    AppUpdaterView(viewModel: AppUpdaterViewModel(
        discover: { _ in [] },
        checkAppStore: { _ in .noResult },
        checkSparkle: { _ in .noResult },
        opener: { _ in }
    ))
    .frame(width: 900, height: 600)
}
