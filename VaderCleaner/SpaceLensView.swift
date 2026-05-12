// SpaceLensView.swift
// Top-level Space Lens detail view — drives the idle/scanning/ready/empty/error states from DiskScannerViewModel, hosts the breadcrumb plus TreemapView, and runs the home-directory scan on first appearance.

import SwiftUI

/// Detail view for the Space Lens sidebar section. Owns nothing of its
/// own — every piece of state lives on `DiskScannerViewModel`. Each
/// `Phase` maps to a dedicated subview (idle → scan call-to-action,
/// scanning → progress bar, ready → breadcrumb + treemap + footer,
/// error → message + try again). The empty case is implicit: a `.ready`
/// node whose subtree has no displayable children renders the empty
/// placeholder inside the same layout, so the breadcrumb stays in
/// reach for navigating back up.
///
/// The first-launch scan targets the user's home directory per the
/// product plan (plan.md line 961). A volume / drive picker lands later
/// once Privacy and App Uninstaller settle. Until then a "Re-scan"
/// button lets the user re-run the same root after deleting files
/// elsewhere in the app.
struct SpaceLensView: View {

    @ObservedObject private var viewModel: DiskScannerViewModel

    init(viewModel: DiskScannerViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle:
                idleState
            case .scanning:
                scanningState
            case .ready:
                if let current = viewModel.currentNode {
                    readyState(current: current)
                } else {
                    // Defensive: `.ready` should always supply a node, but
                    // if `currentNode` somehow returns nil (programming
                    // error), render the idle CTA so the user can recover.
                    idleState
                }
            case .error(let message):
                errorState(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.spaceLens.title)
        // `.onAppear` rather than `.task` so the scan isn't tied to the
        // view's task lifetime — `DiskScannerViewModel` is hoisted to
        // `ContentView` so the scanned tree survives a sidebar peek, and
        // a `.task`-driven scan would be cancelled the moment the user
        // navigated away (the VM's cancellation handler forwards
        // structured cancellation into the in-flight walk). Spawning the
        // scan from an unstructured `Task` inside `onAppear` lets the
        // walk run to completion even while the user browses other
        // sections; `phase`-guarded so re-entering an already-loaded
        // tree doesn't restart the scan.
        .onAppear {
            guard case .idle = viewModel.phase else { return }
            Task { await runScan() }
        }
    }

    // MARK: - States

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: NavigationSection.spaceLens.icon)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Space Lens")
                .font(.title2.weight(.semibold))
            Text("Visualize disk usage in your home folder. Scan to see which folders take up the most space.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan") {
                Task { await runScan() }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("space-lens.scan")
        }
        .padding()
    }

    private var scanningState: some View {
        VStack(spacing: 16) {
            ProgressView(value: viewModel.scanProgress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
            Text("Scanning…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-lens.scanning")
    }

    private func readyState(current: DiskNode) -> some View {
        VStack(spacing: 0) {
            breadcrumb(current: current)
            Divider()
            treemapOrEmpty(current: current)
            Divider()
            footer(current: current)
        }
    }

    /// Empty placeholder shown when the current node has no displayable
    /// children. Takes the treemap's slot inside `readyState` rather than
    /// the whole detail surface so the breadcrumb stays available — the
    /// user can still navigate back up.
    private func treemapOrEmpty(current: DiskNode) -> some View {
        Group {
            if hasDisplayableChildren(current) {
                TreemapView(viewModel: viewModel, node: current)
            } else {
                emptyTreemapPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTreemapPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("This folder appears to be empty")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-lens.empty")
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Couldn't complete the scan")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("space-lens.errorMessage")
            Button("Try Again") {
                Task { await runScan() }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("space-lens.tryAgain")
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-lens.error")
    }

    // MARK: - Breadcrumb + footer

    /// Renders `[root] + viewModel.navigationPath` as clickable chevrons.
    /// The trailing crumb is the current node and is not interactive
    /// (clicking it would be a no-op). Earlier crumbs route through
    /// `viewModel.navigate(to:)` which truncates the path in one call.
    @ViewBuilder
    private func breadcrumb(current: DiskNode) -> some View {
        // Build the crumb sequence from `[root, ...path]`. Avoid using
        // `currentNode` here because the root crumb has special handling
        // (clicking it pops back to root regardless of how deep we are).
        if let root = viewModel.root {
            let crumbs: [DiskNode] = [root] + viewModel.navigationPath
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                        breadcrumbCrumb(
                            crumb: crumb,
                            isCurrent: crumb === current,
                            isRoot: index == 0,
                            tapIndex: index
                        )
                        if index < crumbs.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func breadcrumbCrumb(
        crumb: DiskNode,
        isCurrent: Bool,
        isRoot: Bool,
        tapIndex: Int
    ) -> some View {
        Button {
            // The root crumb empties the path; intermediate crumbs
            // truncate via `navigate(to:)`. Both end with the named
            // crumb at `currentNode`, but the root-special case routes
            // through `navigateToRoot()` so the VM owns the "jump to
            // root" semantics instead of the view mutating
            // `navigationPath` directly.
            if isRoot {
                viewModel.navigateToRoot()
            } else {
                viewModel.navigate(to: crumb)
            }
        } label: {
            Text(crumb.name)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .accessibilityIdentifier("space-lens.breadcrumb.\(tapIndex)")
    }

    private func footer(current: DiskNode) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(current.formattedSize)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("space-lens.totalSize")
            }
            Spacer()
            Button("Re-scan") {
                Task { await runScan() }
            }
            .accessibilityIdentifier("space-lens.rescan")
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func hasDisplayableChildren(_ node: DiskNode) -> Bool {
        node.children.contains { $0.size > 0 }
    }

    /// Kick off a scan rooted at the home directory. The user's home is
    /// the right default — Space Lens is "where on this volume are *my*
    /// files" 95% of the time, and scanning the whole volume root would
    /// stall for minutes on `/System` content the user cannot manage.
    private func runScan() async {
        await viewModel.startScan(root: Self.homeDirectoryURL)
    }

    /// Resolve the home directory once at module load so the runtime
    /// never re-derives it. `URL(fileURLWithPath:)` against
    /// `NSHomeDirectory()` returns the same path the rest of the app
    /// (Large & Old Files, etc.) uses for user-file scans.
    private static let homeDirectoryURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
    }()
}

#Preview("Idle") {
    SpaceLensView(
        viewModel: DiskScannerViewModel(scanner: { _, _ in
            DiskNode(
                url: URL(fileURLWithPath: "/"),
                name: "/",
                size: 0,
                isDirectory: true,
                children: []
            )
        })
    )
    .frame(width: 800, height: 520)
}
