// HomebrewFacetContent.swift
// Right-column content for the Homebrew facet of the Uninstaller and Updater panes — the installed-package list with reclaim actions, and the outdated-package list — styled with the shared manager chrome.

import SwiftUI

/// The Uninstaller pane's Homebrew facet: reclaim actions (cleanup / orphans)
/// above the installed-package list, with batch checkboxes that feed the
/// manager footer's Uninstall action and a dependency-aware confirmation sheet.
struct HomebrewUninstallContent: View {

    @Bindable var viewModel: HomebrewViewModel
    let search: String
    @Binding var selection: Set<BrewPackage.ID>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Homebrew", comment: "Homebrew uninstaller pane title."),
                description: String(localized: "Remove Homebrew packages and reclaim disk from stale downloads.", comment: "Homebrew uninstaller pane description.")
            )
            if case .notInstalled = viewModel.phase {
                HomebrewChrome.notInstalled
            } else {
                reclaimActions
                HomebrewChrome.banner(viewModel)
                list
            }
        }
        .overlay(alignment: .bottom) { HomebrewChrome.progressOverlay(viewModel) }
        .sheet(item: uninstallSheetBinding) { box in
            HomebrewUninstallSheet(
                confirmation: box.confirmation,
                onCancel: viewModel.cancelUninstallRequest,
                onConfirm: { Task { await viewModel.confirmUninstall() } }
            )
        }
    }

    private var reclaimActions: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Preview Cleanup", comment: "Homebrew reclaim action.")) {
                Task { await viewModel.previewCleanup() }
            }
            Button(String(localized: "Run Cleanup", comment: "Homebrew reclaim action.")) {
                Task { await viewModel.runCleanup() }
            }
            Button(String(localized: "Remove Orphans", comment: "Homebrew reclaim action.")) {
                Task { await viewModel.runAutoremove() }
            }
            .help(String(localized: "brew autoremove — removes dependencies no longer required by any package.", comment: "Remove Orphans help."))
            Spacer()
            reclaimStatus
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(viewModel.isBusy)
        .padding(.horizontal, 24).padding(.top, 12)
    }

    @ViewBuilder
    private var reclaimStatus: some View {
        if case .bytes(let bytes) = viewModel.reclaimablePreview {
            Text(String.localizedStringWithFormat(
                String(localized: "About %@ can be freed.", comment: "Homebrew reclaimable preview."),
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            ))
            .font(.caption).foregroundStyle(.secondary)
        } else if case .unavailable = viewModel.reclaimablePreview {
            Text(String(localized: "Nothing to reclaim.", comment: "Homebrew nothing-to-reclaim."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var list: some View {
        let items = filtered
        if items.isEmpty {
            ApplicationsManagerEmptyState(
                icon: "shippingbox",
                title: String(localized: "Homebrew", comment: "Homebrew empty title."),
                detail: String(localized: "No Homebrew packages match this view.", comment: "Homebrew empty detail.")
            )
            .accessibilityIdentifier("applications.manager.homebrew.empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { package in row(package) }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .accessibilityIdentifier("applications.manager.homebrew.list")
        }
    }

    private func row(_ package: BrewPackage) -> some View {
        HStack(spacing: 12) {
            ApplicationsManagerCheckbox(selected: selection.contains(package.id)) {
                if selection.contains(package.id) { selection.remove(package.id) }
                else { selection.insert(package.id) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(package.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(package.installedVersions.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HomebrewChrome.kindLabel(package.kind)
            if package.isLeaf {
                Text(String(localized: "Leaf", comment: "Leaf package label."))
                    .font(.caption).foregroundStyle(.tint)
                    .help(String(localized: "Nothing depends on this — safe to remove.", comment: "Leaf help."))
            }
        }
        .padding(12)
        .managerRowCard()
    }

    private var filtered: [BrewPackage] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.inventory }
        return viewModel.inventory.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var uninstallSheetBinding: Binding<HomebrewUninstallBox?> {
        Binding(
            get: { viewModel.pendingUninstall.map { HomebrewUninstallBox(confirmation: $0) } },
            set: { if $0 == nil { viewModel.cancelUninstallRequest() } }
        )
    }
}

/// The Updater pane's Homebrew facet: the outdated-package list with batch
/// checkboxes that feed the manager footer's Upgrade action.
struct HomebrewOutdatedContent: View {

    @Bindable var viewModel: HomebrewViewModel
    let search: String
    @Binding var selection: Set<BrewOutdatedItem.ID>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ApplicationsManagerPaneHeader(
                title: String(localized: "Homebrew", comment: "Homebrew updater pane title."),
                description: String(localized: "Packages with a newer version available.", comment: "Homebrew updater pane description.")
            )
            if case .notInstalled = viewModel.phase {
                HomebrewChrome.notInstalled
            } else {
                HomebrewChrome.banner(viewModel)
                list
            }
        }
        .overlay(alignment: .bottom) { HomebrewChrome.progressOverlay(viewModel) }
    }

    @ViewBuilder
    private var list: some View {
        if case .checkingUpdates = viewModel.phase {
            HomebrewChrome.centered { ProgressView(String(localized: "Checking for updates…", comment: "Homebrew update-check progress.")) }
        } else {
            let items = filtered
            if items.isEmpty {
                ApplicationsManagerEmptyState(
                    icon: "arrow.down.circle",
                    title: String(localized: "Homebrew", comment: "Homebrew updates empty title."),
                    detail: String(localized: "Every Homebrew package is up to date.", comment: "Homebrew updates empty detail.")
                )
                .accessibilityIdentifier("applications.manager.homebrew.updates.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in row(item) }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
                .accessibilityIdentifier("applications.manager.homebrew.updates.list")
            }
        }
    }

    private func row(_ item: BrewOutdatedItem) -> some View {
        HStack(spacing: 12) {
            ApplicationsManagerCheckbox(selected: selection.contains(item.id)) {
                guard !item.isPinned else { return }
                if selection.contains(item.id) { selection.remove(item.id) }
                else { selection.insert(item.id) }
            }
            .opacity(item.isPinned ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(item.installedVersion) → \(item.candidateVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HomebrewChrome.kindLabel(item.kind)
            if item.isPinned {
                Label(String(localized: "Pinned", comment: "Pinned formula label."), systemImage: "pin.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .help(String(localized: "Pinned formulae are held back from upgrades.", comment: "Pinned help."))
            }
        }
        .padding(12)
        .managerRowCard()
    }

    private var filtered: [BrewOutdatedItem] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.outdated }
        return viewModel.outdated.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}

// MARK: - Shared chrome

/// Small view helpers shared by the two Homebrew facet contents. `@MainActor`
/// because several read the `@MainActor`-isolated view model.
@MainActor
enum HomebrewChrome {

    static func kindLabel(_ kind: BrewPackageKind) -> some View {
        Text(kind == .cask
             ? String(localized: "Cask", comment: "Cask kind label.")
             : String(localized: "Formula", comment: "Formula kind label."))
            .font(.caption).foregroundStyle(.secondary)
    }

    static var notInstalled: some View {
        centered {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(String(localized: "Homebrew isn't installed", comment: "Homebrew not-installed title."))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "Install Homebrew to manage command-line tools and casks from here.", comment: "Homebrew not-installed detail."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Link(String(localized: "Get Homebrew at brew.sh", comment: "Homebrew install link."),
                     destination: URL(string: "https://brew.sh")!)
            }
            .frame(maxWidth: 360)
        }
        .accessibilityIdentifier("applications.manager.homebrew.notInstalled")
    }

    @ViewBuilder
    static func banner(_ viewModel: HomebrewViewModel) -> some View {
        if let notice = viewModel.manualHandling {
            VStack(alignment: .leading, spacing: 6) {
                Label(String(localized: "This package needs Terminal", comment: "Homebrew manual-handling title."), systemImage: "terminal")
                    .font(.callout.weight(.medium))
                Text(notice.command)
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                Button(String(localized: "Dismiss", comment: "Dismiss manual-handling notice."), action: viewModel.dismissManualHandling)
                    .font(.caption)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
            .padding(.horizontal, 24).padding(.top, 8)
            .accessibilityIdentifier("applications.manager.homebrew.manualHandling")
        } else if let error = viewModel.lastOperationError {
            Text(error).font(.callout).foregroundStyle(.orange)
                .padding(.horizontal, 24).padding(.top, 8)
        }
    }

    @ViewBuilder
    static func progressOverlay(_ viewModel: HomebrewViewModel) -> some View {
        if case .running(let operation) = viewModel.phase {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(operationLabel(operation)).font(.callout.weight(.medium))
                    Spacer()
                    Button(String(localized: "Cancel", comment: "Cancel a running brew operation."), action: viewModel.cancelActiveOperation)
                        .accessibilityIdentifier("applications.manager.homebrew.cancel")
                }
                if let last = viewModel.liveLog.last {
                    Text(last).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(16)
        }
    }

    static func centered<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func operationLabel(_ operation: HomebrewViewModel.Operation) -> String {
        switch operation {
        case .upgrade:    return String(localized: "Upgrading…", comment: "Homebrew progress label.")
        case .uninstall:  return String(localized: "Uninstalling…", comment: "Homebrew progress label.")
        case .cleanup:    return String(localized: "Cleaning up…", comment: "Homebrew progress label.")
        case .autoremove: return String(localized: "Removing orphans…", comment: "Homebrew progress label.")
        }
    }
}

/// Identifiable wrapper so `UninstallConfirmation` can drive `.sheet(item:)`.
struct HomebrewUninstallBox: Identifiable {
    let confirmation: UninstallConfirmation
    var id: String { confirmation.targets.map(\.id).joined(separator: ",") }
}

/// Confirmation sheet listing the packages to remove and any installed
/// dependents that would be affected.
struct HomebrewUninstallSheet: View {
    let confirmation: UninstallConfirmation
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)

            if confirmation.hasBlockingDependents {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "Other packages depend on this", comment: "Uninstall dependents warning."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout.weight(.medium))
                    ForEach(confirmation.targets, id: \.id) { target in
                        if let dependents = confirmation.dependents[target.name], !dependents.isEmpty {
                            Text("\(target.name): \(dependents.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(String(localized: "Removing it may break those packages.", comment: "Uninstall dependents caveat."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            } else {
                Text(String(localized: "Nothing installed depends on this.", comment: "Uninstall no-dependents note."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Cancel uninstall."), role: .cancel, action: onCancel)
                Button(String(localized: "Uninstall", comment: "Confirm uninstall."), role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 420)
    }

    private var title: String {
        if confirmation.targets.count == 1 {
            return String.localizedStringWithFormat(
                String(localized: "Uninstall %@?", comment: "Uninstall confirmation title, single package."),
                confirmation.targets[0].name
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "Uninstall %lld packages?", comment: "Uninstall confirmation title, multiple."),
            Int64(confirmation.targets.count)
        )
    }
}
