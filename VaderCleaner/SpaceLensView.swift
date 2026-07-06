// SpaceLensView.swift
// Top-level Space Lens detail view — drives the scanning/ready/error states, and in the ready state composes the breadcrumb bar, the left selection list, the bubble chart, the bottom volume/selection bar, and the review-before-removal overlay.

import SwiftUI
import AppKit

/// Detail view for the Space Lens section. Owns no scan state — everything lives
/// on `DiskScannerViewModel`. The unified flow shows the Scan landing while the
/// coordinator reports `.intro`; this view renders the non-intro phases:
/// `.scanning` (progress), `.ready` (the explorer), and `.error`.
///
/// The ready layout mirrors the reference design: a breadcrumb bar with
/// back / forward / Start Over controls, a left list panel beside the packed
/// bubble chart, and a pinned bottom bar with the volume gauge and the
/// Review and Remove action. Selecting items and confirming in the review
/// overlay moves them to the Trash.
struct SpaceLensView: View {

    private var viewModel: DiskScannerViewModel

    /// Real Finder icons for the volume, folders, apps, and files shown in the
    /// list and bubbles — so System, Applications, Library, the user's home, etc.
    /// render with their actual macOS icons rather than generic glyphs.
    @State private var iconCache = AppIconCache(
        placeholderIcon: NSWorkspace.shared.icon(for: .folder)
    )

    init(viewModel: DiskScannerViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle:
                // Unreachable: ScannableSectionContent shows the intro while the
                // coordinator reports `.intro` (which `.idle` maps to), so the
                // detail view isn't built in this phase. Kept for exhaustiveness.
                EmptyView()
            case .scanning:
                scanningState
            case .ready:
                if let current = viewModel.currentNode, let root = viewModel.root {
                    readyState(current: current, root: root)
                } else {
                    EmptyView()
                }
            case .error(let message):
                errorState(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.spaceLens.title)
    }

    // MARK: - Scanning / error

    private var scanningState: some View {
        VStack(spacing: 16) {
            ScanProgressIndicator()
            ScanningStatusView(
                phrases: ScanPhrases.scanning(for: .spaceLens),
                count: ScanProgressFormatting.itemsScanned(viewModel.scannedItemCount),
                countIdentifier: "space-lens.scanning.count"
            )
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-lens.scanning")
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
            Button("Try Again") { viewModel.beginScan() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("space-lens.tryAgain")
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-lens.error")
    }

    // MARK: - Ready

    private func readyState(current: DiskNode, root: DiskNode) -> some View {
        // Compute the display rows once per render here (not in each subview's
        // body), so the child sort isn't re-run on every hover. This body only
        // re-renders on navigation / phase / review changes — not on hover or
        // selection, which are local to the subviews.
        let items = SpaceLensChildren.displayed(for: current)
        return ZStack {
            // The explorer and the review overlay swap with the same
            // slide-and-fade the left-nav sections use: opening Review sends
            // the explorer up and out through the top, then the review window
            // follows up from the bottom into place, so the explorer is never
            // left sitting behind the window. Closing reverses through the
            // same upward motion.
            if viewModel.reviewActive {
                reviewOverlay(root: root)
                    .transition(.spaceLensReview)
            } else {
                explorer(current: current, items: items)
                    .transition(.spaceLensReview)
            }
        }
        // Span the full sequential transition (exit + entry delay + entry
        // ≈ 1.1s) so the delayed insertion isn't cancelled and snapped into
        // place — matching the detail pane's section transaction.
        .animation(.smooth(duration: 1.2), value: viewModel.reviewActive)
        .task(id: current.id) { await preloadIcons(items: items, current: current) }
    }

    /// The explorer screen: breadcrumb bar, the left list beside the bubble
    /// chart, and the bottom volume/selection bar. Slides up and out when the
    /// review overlay takes over.
    private func explorer(current: DiskNode, items: [SpaceLensDisplayItem]) -> some View {
        VStack(spacing: 0) {
            startOverBar
            breadcrumbBar(current: current)
            HStack(spacing: 20) {
                SpaceLensListPanel(viewModel: viewModel, node: current, items: items, iconCache: iconCache)
                    .frame(width: 360)
                bubbleArea(current: current, items: items)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
            SpaceLensBottomBar(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Pre-load the real icons for the current folder, its displayed children,
    /// and the aggregated "Other items" tail, so rows and bubbles render their
    /// Finder icons without a synchronous `NSWorkspace` call inside `body`.
    private func preloadIcons(items: [SpaceLensDisplayItem], current: DiskNode) async {
        var urls = [current.url]
        urls += items.compactMap { $0.node?.url }
        urls += items.flatMap { $0.aggregatedChildren.map(\.url) }
        await iconCache.preloadIcons(for: urls)
    }

    /// Top-left "Start Over" control, mirroring the other section dashboards.
    private var startOverBar: some View {
        HStack {
            Button(action: { viewModel.reset() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Start Over")
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("space-lens.startOver")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func bubbleArea(current: DiskNode, items: [SpaceLensDisplayItem]) -> some View {
        if current.children.contains(where: { $0.size > 0 }) {
            SpaceLensBubbleView(viewModel: viewModel, node: current, items: items, iconCache: iconCache)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
    }

    private func reviewOverlay(root: DiskNode) -> some View {
        ZStack {
            // The explorer is swapped out beneath, so the window sits on the
            // section backdrop with nothing behind it. A near-transparent
            // catcher keeps the tap-outside-to-dismiss affordance without
            // dimming the backdrop.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { viewModel.reviewActive = false }
            SpaceLensReviewSheet(viewModel: viewModel, root: root, iconCache: iconCache)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Breadcrumb bar

    private func breadcrumbBar(current: DiskNode) -> some View {
        HStack(spacing: 8) {
            // Back / forward on the leading edge.
            navButton(system: "chevron.left", enabled: viewModel.canGoBack) { viewModel.goBack() }
                .accessibilityIdentifier("space-lens.back")
            navButton(system: "chevron.right", enabled: viewModel.canGoForward) { viewModel.goForward() }
                .accessibilityIdentifier("space-lens.forward")

            // Crumbs centered between flexible spacers, with a trailing spacer
            // balancing the nav buttons so they sit centered in the whole bar
            // and never overlap the controls.
            Spacer(minLength: 12)
            breadcrumb(current: current)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Color.clear.frame(width: Self.navControlsWidth, height: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        // Plain (un-tinted) glass on the bar's slimmer radius: the white tile
        // tint made this wide strip read as a bright-rimmed slab, so the
        // chrome keeps the quieter regular material.
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    /// Combined width of the two nav buttons, reserved on the trailing side so
    /// the centered breadcrumb is balanced against them.
    private static let navControlsWidth: CGFloat = 64

    private func navButton(system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func breadcrumb(current: DiskNode) -> some View {
        if let root = viewModel.root {
            let crumbs: [DiskNode] = [root] + viewModel.navigationPath
            HStack(spacing: 6) {
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
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func breadcrumbCrumb(crumb: DiskNode, isCurrent: Bool, isRoot: Bool, tapIndex: Int) -> some View {
        Button {
            if isRoot { viewModel.navigateToRoot() } else { viewModel.navigate(to: crumb) }
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: iconCache.icon(for: crumb.url))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(crumb.name)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .accessibilityIdentifier("space-lens.breadcrumb.\(tapIndex)")
    }
}

private extension AnyTransition {
    /// Slide-and-fade swap between the explorer and the review window, matching
    /// the detail pane's upward section transition: the outgoing screen exits
    /// through the top while the incoming screen follows up from the bottom.
    /// The two halves run sequentially — the insertion is delayed until the
    /// removal has cleared — so only one screen is on the way through at a time.
    static var spaceLensReview: AnyTransition {
        let exitDuration: Double = 0.55
        let entryDuration: Double = 0.55
        return .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .animation(.smooth(duration: entryDuration).delay(exitDuration)),
            removal: .move(edge: .top)
                .combined(with: .opacity)
                .animation(.smooth(duration: exitDuration))
        )
    }
}

#Preview("Ready") {
    let child = DiskNode(url: URL(fileURLWithPath: "/Users/me/Movies"), name: "Movies",
                         size: 257_000_000_000, isDirectory: true, children: [], itemCount: 1200)
    let docs = DiskNode(url: URL(fileURLWithPath: "/Users/me/Documents"), name: "Documents",
                        size: 110_000_000_000, isDirectory: true, children: [], itemCount: 800)
    let root = DiskNode(url: URL(fileURLWithPath: "/"), name: "Macintosh HD",
                        size: 367_000_000_000, isDirectory: true, children: [child, docs], itemCount: 2000)
    let vm = DiskScannerViewModel(
        scanner: { _, _ in root },
        volumeUsageProvider: { _ in SpaceLensVolumeUsage(volumeName: "Macintosh HD", usedBytes: 1_300_000_000_000, totalBytes: 2_000_000_000_000) }
    )
    return SpaceLensView(viewModel: vm)
        .frame(width: 1000, height: 640)
        .task { await vm.startScan(root: URL(fileURLWithPath: "/")) }
}
