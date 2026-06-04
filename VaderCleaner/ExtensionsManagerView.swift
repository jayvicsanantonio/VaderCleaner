// ExtensionsManagerView.swift
// Extensions Manager feature view — discovers Safari/browser extensions, Mail plugins, internet plug-ins, and login-item launch agents, groups them by type, and removes the selected one after confirmation.

import SwiftUI

/// Detail view shown when the user selects "Extensions" in the sidebar.
/// A single grouped list (one section per `ExtensionType`) with a per-row
/// Remove control; the view-model owns the state machine and side-effects.
struct ExtensionsManagerView: View {

    private var viewModel: ExtensionsManagerViewModel
    @State private var pendingRemoval: ExtensionItem?

    init(viewModel: ExtensionsManagerViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(
                localized: "Extensions",
                comment: "Navigation title of the Extensions Manager screen."
            ))
            .task {
                if viewModel.phase == .idle {
                    await viewModel.refresh()
                }
            }
            .alert(
                removalConfirmationTitle,
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                )
            ) {
                Button(String(
                    localized: "Cancel",
                    comment: "Cancel button on the Extensions Manager removal confirmation alert."
                ), role: .cancel) {
                    pendingRemoval = nil
                }
                Button(String(
                    localized: "Remove",
                    comment: "Confirm-removal button on the Extensions Manager removal confirmation alert."
                ), role: .destructive) {
                    if let item = pendingRemoval {
                        pendingRemoval = nil
                        Task { await viewModel.remove(item) }
                    }
                }
            } message: {
                Text(removalConfirmationMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ExtensionsManagerProgressState(
                label: String(
                    localized: "Scanning for extensions…",
                    comment: "Progress label while the Extensions Manager runs discovery."
                ),
                identifier: "extensions.loading"
            )
        case .removing:
            ExtensionsManagerProgressState(
                label: String(
                    localized: "Removing…",
                    comment: "Progress label while the Extensions Manager removes an item."
                ),
                identifier: "extensions.removing"
            )
        case .ready:
            if viewModel.groupedByType.isEmpty {
                ExtensionsManagerEmptyState(
                    onRefresh: { Task { await viewModel.refresh() } }
                )
            } else {
                ExtensionsManagerList(
                    groups: viewModel.groupedByType,
                    onRemove: { pendingRemoval = $0 },
                    onRefresh: { Task { await viewModel.refresh() } }
                )
            }
        case .failed(let stage, let message):
            ExtensionsManagerFailedState(
                stage: stage,
                message: message,
                onPrimary: {
                    switch stage {
                    case .loading:
                        Task { await viewModel.refresh() }
                    case .removing:
                        viewModel.dismissResult()
                    }
                }
            )
        }
    }

    private var removalConfirmationTitle: String {
        String(
            localized: "Remove this extension?",
            comment: "Alert title asking the user to confirm removing an extension."
        )
    }

    private var removalConfirmationMessage: String {
        if let item = pendingRemoval {
            let format = String(
                localized: "%@ will be permanently deleted from disk. This cannot be undone.",
                comment: "Alert message confirming an extension removal."
            )
            return String.localizedStringWithFormat(format, item.name)
        }
        return String(
            localized: "The selected extension will be permanently deleted from disk.",
            comment: "Fallback alert message confirming an extension removal."
        )
    }
}

#Preview {
    ExtensionsManagerView(viewModel: ExtensionsManagerViewModel(
        discover: {
            [
                ExtensionItem(name: "uBlock Origin",
                              path: URL(fileURLWithPath: "/tmp/ublock"),
                              bundleID: "org.ublock",
                              type: .chromeExtension,
                              isEnabled: true,
                              size: 5_242_880),
                ExtensionItem(name: "GPGMail",
                              path: URL(fileURLWithPath: "/tmp/GPGMail.mailbundle"),
                              bundleID: "org.gpgtools.gpgmail",
                              type: .mailPlugin,
                              isEnabled: false,
                              size: 2_048)
            ]
        },
        remove: { _ in }
    ))
    .frame(width: 900, height: 600)
}
