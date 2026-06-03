// AppUninstallerView.swift
// App Uninstaller feature view — orchestrates app discovery, selection, associated-files inspection, and destructive uninstall.

import SwiftUI

/// Detail view shown when the user selects "App Uninstaller" in the sidebar.
/// Two-pane layout: searchable installed-app list on the left, associated-
/// files inspector + uninstall control on the right. The view-model owns
/// the state machine and the actual side-effects.
struct AppUninstallerView: View {

    private var viewModel: AppUninstallerViewModel
    @State private var iconCache: AppIconCache
    @Environment(ExclusionsStore.self) private var exclusions
    @State private var showUninstallConfirmation = false

    init(viewModel: AppUninstallerViewModel, iconCache: AppIconCache = AppIconCache()) {
        self.viewModel = viewModel
        _iconCache = State(initialValue: iconCache)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(phaseTransitionID)
            .transition(.opacity)
            .animation(.smooth(duration: 0.35), value: phaseTransitionID)
            .navigationTitle(String(
                localized: "App Uninstaller",
                comment: "Navigation title for the App Uninstaller screen, reused as an Applications detail screen."
            ))
            .task {
                if viewModel.phase == .idle {
                    await viewModel.loadApps()
                }
            }
            .alert(uninstallConfirmationTitle, isPresented: $showUninstallConfirmation) {
                Button(String(
                    localized: "Cancel",
                    comment: "Cancel button on the App Uninstaller confirmation alert."
                ), role: .cancel) { }
                Button(uninstallConfirmActionLabel, role: .destructive) {
                    Task { await viewModel.uninstall() }
                }
            } message: {
                Text(uninstallConfirmationMessage)
            }
    }

    /// Best-effort *prediction* that the selected app will be permanently
    /// removed rather than moved to the Trash, used to phrase the
    /// confirmation alert. A bundle the current user can't write (root-owned
    /// App Store or pkg-installed apps) can't be moved to the Trash, so the
    /// uninstaller removes it permanently through the privileged helper. The
    /// completion screen does not rely on this guess — it reflects the actual
    /// recycle outcome.
    private var selectedAppIsPermanentRemoval: Bool {
        guard let app = viewModel.selectedApp else { return false }
        return !FileManager.default.isWritableFile(atPath: app.bundleURL.path)
    }

    /// Stable per-phase token so moving between flow phases crossfades
    /// instead of hard-cutting. Distinct phases map to distinct strings;
    /// associated values are intentionally ignored — only the phase identity
    /// drives the transition.
    private var phaseTransitionID: String {
        switch viewModel.phase {
        case .idle:         return "idle"
        case .loading:      return "loading"
        case .ready:        return "ready"
        case .uninstalling: return "uninstalling"
        case .complete:     return "complete"
        case .failed:       return "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            AppUninstallerProgressState(label: String(
                                            localized: "Discovering installed apps…",
                                            comment: "Progress label while the App Uninstaller scans for installed apps."
                                        ),
                                         identifier: "appUninstaller.loading")
        case .ready:
            readyContent
        case .uninstalling:
            AppUninstallerProgressState(label: String(
                                            localized: "Moving to Trash…",
                                            comment: "Progress label while the App Uninstaller is moving items to Trash."
                                        ),
                                         identifier: "appUninstaller.uninstalling")
        case .complete(let bytes, let permanentRemoval):
            AppUninstallerCompleteState(bytesFreed: bytes,
                                        isPermanentRemoval: permanentRemoval,
                                        onContinue: viewModel.dismissResult)
        case .failed(let stage, let message, let helperConnectionIssue):
            AppUninstallerFailedState(stage: stage,
                                     message: message,
                                     canReinstallHelper: helperConnectionIssue,
                                     onReinstallHelper: { Task { await viewModel.reinstallHelper() } },
                                     onTryAgain: { Task { await viewModel.loadApps() } })
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        HStack(spacing: 0) {
            AppUninstallerListPane(
                apps: viewModel.filteredApps,
                selectedAppID: viewModel.selectedAppID,
                bundleSize: viewModel.bundleSize(for:),
                searchQuery: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.searchQuery = $0 }
                ),
                includesSystemApps: Binding(
                    get: { viewModel.includesSystemApps },
                    set: { newValue in
                        guard newValue != viewModel.includesSystemApps else { return }
                        viewModel.includesSystemApps = newValue
                        Task { await viewModel.reloadApps() }
                    }
                ),
                onSelect: viewModel.select,
                onAddToExclusions: { exclusions.add(path: $0.bundleURL.path) },
                iconCache: iconCache
            )
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            Divider()
            AppUninstallerDetailPane(
                app: viewModel.selectedApp,
                bundleSize: viewModel.selectedAppBundleSize,
                isLoadingAssociatedFiles: viewModel.isLoadingAssociatedFiles,
                groupedFiles: viewModel.associatedFilesByCategory,
                totalReclaimableSize: viewModel.totalReclaimableSize,
                canUninstall: viewModel.canUninstallSelectedApp,
                onUninstall: { showUninstallConfirmation = true },
                iconCache: iconCache
            )
        }
        .onChange(of: viewModel.filteredApps.map(\.id)) { _, _ in
            Task { await iconCache.preloadIcons(for: viewModel.filteredApps.map(\.bundleURL)) }
        }
        .task(id: viewModel.apps.map(\.id)) {
            await iconCache.preloadIcons(for: viewModel.apps.map(\.bundleURL))
        }
    }

    private var uninstallConfirmationTitle: String {
        if selectedAppIsPermanentRemoval {
            return String(
                localized: "Permanently remove this app?",
                comment: "Alert title confirming removal of an App Store app that can't be moved to the Trash."
            )
        }
        return String(
            localized: "Move app and its data to Trash?",
            comment: "Alert title asking the user to confirm uninstalling an app."
        )
    }

    private var uninstallConfirmActionLabel: String {
        if selectedAppIsPermanentRemoval {
            return String(
                localized: "Remove",
                comment: "Confirm-uninstall button when the app will be permanently removed."
            )
        }
        return String(
            localized: "Move to Trash",
            comment: "Confirm-uninstall button on the App Uninstaller confirmation alert."
        )
    }

    private var uninstallConfirmationMessage: String {
        guard let app = viewModel.selectedApp else {
            return String(
                localized: "The selected app and its associated files will be moved to the Trash.",
                comment: "Fallback alert message confirming an app uninstall when the app name is unavailable."
            )
        }
        if selectedAppIsPermanentRemoval {
            // App Store apps are installed root-owned; the app itself can't be
            // sent to the Trash, so it is permanently removed. Its user-domain
            // data still goes to the Trash and stays restorable.
            let format = String(
                localized: "%@ was installed from the App Store and will be permanently removed — it can't be moved to the Trash. Its associated files will be moved to the Trash.",
                comment: "Alert message confirming permanent removal of an App Store app."
            )
            return String.localizedStringWithFormat(format, app.name)
        }
        let format = String(
            localized: "%@ and its associated files will be moved to the Trash. You can restore them from the Trash until you empty it.",
            comment: "Alert message confirming an app uninstall."
        )
        return String.localizedStringWithFormat(format, app.name)
    }
}

#Preview {
    AppUninstallerView(viewModel: AppUninstallerViewModel(
        discover: { _ in [] },
        findFiles: { _ in [] },
        recycle: { _, _ in AppUninstallerViewModel.RecycleOutcome(bytesFreed: 0, bundlePermanentlyRemoved: false) }
    ))
    .frame(width: 900, height: 600)
    .environment(ExclusionsStore(defaults: UserDefaults(suiteName: "preview")!))
}
