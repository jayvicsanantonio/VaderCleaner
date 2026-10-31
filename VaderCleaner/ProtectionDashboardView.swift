// ProtectionDashboardView.swift
// The Protection results dashboard — a live malware-scan tile beside privacy result tiles that fill in as each scan becomes ready, mirroring the CleanMyMac Protection grid.

import SwiftUI
import AppKit
import VaderCleanerCore

/// Renders the Protection section's dashboard: a Start Over bar, a centered
/// header, and a grid whose left tile shows the live malware scan while the
/// right column fills with privacy tiles as the (faster) privacy preview
/// completes. Composes `ProtectionDashboardViewModel`'s two child flows; this
/// view owns only presentation state (which sheet/alert is up).
struct ProtectionDashboardView: View {

    let viewModel: ProtectionDashboardViewModel

    /// Which surface the section shows: the results dashboard, or the dedicated
    /// Protection Manager opened by "Manage Privacy Items" / a card's Review.
    private enum Detail { case dashboard, manager }

    @State private var detail: Detail = .dashboard
    @State private var onboardingViewModel = MalwareOnboardingViewModel()
    @State private var reviewingThreats = false
    @State private var confirmingMalwareRemoval = false
    /// Set when the review sheet hands off to the removal alert. The alert waits
    /// for the sheet's dismissal, since presenting it while the sheet is still on
    /// its way out can lose it.
    @State private var confirmRemovalAfterReview = false
    @State private var pendingPrivacyRemoval: PrivacyRemoval?
    /// Where the button that opened the manager wants it to land.
    @State private var managerFocus: ProtectionManagerFocus?

    /// Browser icons + resolved bundle URLs for the manager's rows, warmed
    /// through the shared `AppIconCache`.
    @State private var iconCache = AppIconCache()
    @State private var browserBundleURLs: [Browser: URL] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the manager zoom anchors: the button that opened it, resolved
    /// by `openManager`. Also the point Back zooms the manager back into.
    @State private var managerAnchor: UnitPoint = .center
    /// The transition host's frame in global space, for mapping the opening
    /// click to `managerAnchor`.
    @State private var paneFrame: CGRect = .zero
    /// The title-bar safe-area inset the transition host permanently claims;
    /// handed back to the dashboard as top padding so only the manager
    /// extends under the title bar.
    @State private var paneTopInset: CGFloat = 0

    private var malware: MalwareViewModel { viewModel.malware }
    private var privacy: PrivacyViewModel { viewModel.privacy }
    private let accent = NavigationSection.malwareRemoval.theme.accent

    var body: some View {
        // The dashboard and the Protection Manager exchange inside
        // `ManagerPresentationHost` (a stable transition host) with the shared
        // manager motion: the manager zooms up from the button that opened it
        // over the receding dashboard, and zooms back into it on Back — after
        // which it stays mounted (hidden), so reopening restores its panes
        // instantly.
        ManagerPresentationHost(
            isPresented: detail == .manager,
            anchor: managerAnchor,
            reduceMotion: reduceMotion,
            dashboardTopInset: paneTopInset
        ) {
            dashboardSurface
        } manager: {
            ProtectionManagerView(
                malware: malware,
                privacyModel: viewModel.protectionPrivacy,
                iconCache: iconCache,
                bundleURL: { browserBundleURLs[$0] },
                focus: $managerFocus,
                onBack: { detail = .dashboard }
            )
        }
        // Both alerts sit outside the host because either surface can raise them:
        // a tile's Remove and the manager's lead to the same failures and blocks.
        .modifier(RemovalFailureAlert(viewModel: viewModel))
        .modifier(RunningBrowserAlert(model: viewModel.protectionPrivacy))
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { paneFrame = $0 })
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { paneTopInset = $0 })
        // The dashboard appears once a scan has begun. Ensure the privacy
        // preview is running too — covers the Smart Scan seed path, where
        // the dashboard shows without this view's own beginScan.
        .task {
            if privacy.phase == .idle { privacy.beginScan() }
            // The dashboard is often showing results seeded from a Smart Scan,
            // which never reads the signature date — without this the
            // definitions line has nothing to report.
            malware.refreshDatabaseDate()
            viewModel.refreshManagerPrivacy()
        }
        // Coming back from a browser is when its data has most likely changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshRecentItems()
            if detail == .manager { viewModel.refreshManagerPrivacy() }
        }
        // Resolve each detected browser's bundle URL + warm the icon cache for
        // the manager's rows.
        .task(id: privacy.detectedBrowsers) { await loadBrowserIcons() }
    }

    /// Anchors the zoom to the button (or failing that, the click) being
    /// handled, then raises the manager.
    private func openManager() {
        openManager(focusing: .privacy)
    }

    private func openManager(focusing focus: ProtectionManagerFocus) {
        managerAnchor = TriggerAnchor.resolve(in: paneFrame)
        managerFocus = focus
        viewModel.refreshManagerPrivacy()
        detail = .manager
    }

    private var dashboardSurface: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(NavigationSection.malwareRemoval.title)
            // ClamAV "Check Again" reports installation; once present, kick the
            // scan so the user doesn't have to navigate away and back.
            .onChange(of: onboardingViewModel.isInstalled) { _, installed in
                if installed { viewModel.beginScan() }
            }
            .sheet(isPresented: $reviewingThreats, onDismiss: {
                guard confirmRemovalAfterReview else { return }
                confirmRemovalAfterReview = false
                confirmingMalwareRemoval = true
            }) {
                threatsReviewSheet
            }
            .alert(
                String(localized: "Remove all detected threats?",
                       comment: "Alert title confirming malware removal."),
                isPresented: $confirmingMalwareRemoval
            ) {
                Button(String(localized: "Cancel", comment: "Cancel button on the malware removal confirmation alert."), role: .cancel) {}
                Button(String(localized: "Remove", comment: "Confirm button on the malware removal confirmation alert."), role: .destructive) {
                    Task { await malware.removeThreats() }
                }
            } message: {
                // Remove All acts on every detected threat, so the body
                // answers for all of them: Trash, or a permanent delete for
                // any under a protected path.
                if case .results(let threats) = malware.phase {
                    Text(threats.removalConfirmationMessage)
                }
            }
            .alert(
                String(localized: "Remove these items?",
                       comment: "Privacy removal confirmation title."),
                isPresented: Binding(
                    get: { pendingPrivacyRemoval != nil },
                    set: { if !$0 { pendingPrivacyRemoval = nil } }
                )
            ) {
                Button(String(localized: "Cancel", comment: "Cancel privacy removal."), role: .cancel) {}
                if let removal = pendingPrivacyRemoval {
                    Button(String(localized: "Remove", comment: "Confirm privacy removal."), role: .destructive) {
                        performPrivacyRemoval(removal)
                    }
                }
            } message: {
                if let removal = pendingPrivacyRemoval {
                    Text(confirmationMessage(for: removal))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if malware.phase == .needsInstall {
            // Keep the dedicated ClamAV install onboarding for the missing-engine
            // case rather than showing an empty malware tile.
            MalwareOnboardingView(viewModel: onboardingViewModel)
        } else if !privacyReady {
            // Hold the full-screen scanning loader until the privacy tiles' data
            // is ready, so the grid only appears once it can render fully
            // populated — leaving just the slower malware scan to show progress
            // inside its own tile.
            loadingScreen
        } else {
            dashboard
        }
    }

    /// Whether the privacy preview has produced data to render tiles from. The
    /// grid waits on this; the malware scan can still be in flight.
    private var privacyReady: Bool {
        switch privacy.phase {
        case .idle, .scanning:
            return false
        case .preview, .clearing, .complete, .failed:
            return true
        }
    }

    /// The standard full-screen scan loader, driven by the malware scan that is
    /// already running. Shown between tapping Scan and the grid appearing.
    private var loadingScreen: some View {
        MalwareProgressState(
            label: String(localized: "Looking for threats…",
                          comment: "Protection loading-screen label while scans run."),
            identifier: "protection.loading",
            phrases: ScanPhrases.scanning(for: .malwareRemoval)
        )
    }

    /// Resolves each detected browser's `.app` bundle URL via Launch Services
    /// and warms the icon cache, so the manager's browser rows show real icons.
    private func loadBrowserIcons() async {
        var urls: [Browser: URL] = [:]
        for browser in privacy.detectedBrowsers {
            urls[browser] = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: browser.bundleIdentifier)
        }
        browserBundleURLs = urls
        await iconCache.preloadIcons(for: Array(urls.values))
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        VStack(spacing: 0) {
            startOverBar
            VStack(spacing: 18) {
                header
                grid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startOverBar: some View {
        HStack {
            Button(action: viewModel.startOver) {
                Label(
                    String(localized: "Start Over",
                           comment: "Button on the Protection dashboard that resets to the welcome screen."),
                    systemImage: "arrow.counterclockwise"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("protection.startOver")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private var header: some View {
        VStack(spacing: 14) {
            // Section hero, mirroring the Protection intro and the other
            // section dashboards (Applications / My Clutter / Performance) which
            // all crown the header with their section art at the same size.
            Image("malwareRemoval")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 140, maxHeight: 140)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(headerTitle)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                Text(String(
                    localized: "Feel free to adjust privacy items anytime.",
                    comment: "Protection dashboard subtitle."
                ))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            Button(action: openManager) {
                Text(String(
                    localized: "Manage Privacy Items",
                    comment: "Protection dashboard button that opens the Privacy manager."
                ))
                .padding(.horizontal, 8)
            }
            .buttonStyle(.vaderTileGlass)
            .controlSize(.large)
            .accessibilityIdentifier("protection.managePrivacy")

            definitionsLine
        }
        .padding(.top, 4)
    }

    /// How old the signature database is, plus the only way in the app to
    /// refresh it without starting a full scan.
    ///
    /// A scan refreshes signatures on its own, but the stale-definitions
    /// notification asks the user to act and previously left them nowhere to
    /// do it — `updateDatabaseManually()` existed with no caller. Hidden while
    /// a scan is in flight, since a scan does its own refresh.
    @ViewBuilder
    private var definitionsLine: some View {
        if !malware.isScanningPhase {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    if malware.isUpdatingDefinitions {
                        ProgressView().controlSize(.small)
                        Text(String(
                            localized: "Updating malware definitions…",
                            comment: "Protection dashboard definitions status while an update runs."
                        ))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                    } else {
                        Text(definitionsSummary)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            Task { await malware.updateDatabaseManually() }
                        } label: {
                            Text(String(
                                localized: "Update",
                                comment: "Protection dashboard button that refreshes the malware signature database."
                            ))
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.vaderTileGlass)
                        .controlSize(.small)
                        .accessibilityIdentifier("protection.updateDefinitions")
                    }
                }
                if let failure = malware.definitionsUpdateFailure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("protection.updateDefinitions.failure")
                }
            }
        }
    }

    private var definitionsSummary: String {
        guard let days = malware.definitionsAgeInDays else {
            return String(
                localized: "Malware definitions have never been updated",
                comment: "Protection dashboard definitions status when no signatures are present."
            )
        }
        switch days {
        case 0:
            return String(
                localized: "Malware definitions updated today",
                comment: "Protection dashboard definitions status, refreshed today."
            )
        case 1:
            return String(
                localized: "Malware definitions updated yesterday",
                comment: "Protection dashboard definitions status, refreshed yesterday."
            )
        default:
            return String(
                localized: "Malware definitions updated \(days) days ago",
                comment: "Protection dashboard definitions status with the number of days since the last refresh."
            )
        }
    }

    /// "Looking for threats…" while the malware scan is in flight, otherwise a
    /// settled title.
    private var headerTitle: String {
        if malware.isScanningPhase {
            return String(localized: "Looking for threats…",
                          comment: "Protection dashboard heading while the malware scan runs.")
        }
        return String(localized: "Protection",
                      comment: "Protection dashboard heading once the scan is done.")
    }

    // MARK: - Grid

    /// Verbatim the Applications dashboard layout: the live malware tile is the
    /// tall lead card on the left (half the width), and the privacy findings sit
    /// in a right-hand column packed into rows of at most two (an odd count leads
    /// with a single full-width row). Every card fills its share with
    /// `maxHeight: .infinity` — no GeometryReader, no explicit heights — so the
    /// rows divide the height evenly and the two columns stay aligned, exactly
    /// like `ApplicationsDashboardView.cardLayout`. With no privacy findings the
    /// malware tile fills the whole pane.
    /// The ranked 2–4 tiles the dashboard shows: the live malware scan always
    /// leads (safety first — `.critical` once threats are found), then the
    /// privacy findings by reclaimable size (capped so the grid never exceeds
    /// four), backfilled with a reassurance card when privacy is clean.
    private var selectedTiles: [ProtectionDashboardTile] {
        let malwareHasThreats: Bool
        if case .results(let threats) = malware.phase { malwareHasThreats = !threats.isEmpty } else { malwareHasThreats = false }

        var real: [RankedTile<ProtectionDashboardTile>] = [
            RankedTile(payload: .malware,
                       urgency: malwareHasThreats ? .critical : .attention,
                       reclaimableBytes: 0)
        ]
        real.append(contentsOf: privacyTiles.map { tile in
            RankedTile(payload: .privacy(tile), urgency: .space, reclaimableBytes: tile.bytes)
        })
        let reassurance = Self.reassurancePool.map { content in
            RankedTile(payload: ProtectionDashboardTile.reassurance(content),
                       urgency: .reassurance, reclaimableBytes: 0)
        }
        return SectionRecommendationSelector.select(real: real, reassurance: reassurance)
    }

    /// Gap between adjacent tiles, shared by the column and row splits so the
    /// concrete sizing matches the visual spacing.
    private let cardGap: CGFloat = 16

    @ViewBuilder
    private var grid: some View {
        let tiles = selectedTiles
        if tiles.count <= 1 {
            if let only = tiles.first {
                tileView(only)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // Size each tile concretely from the pane geometry rather than
            // nesting `.frame(maxWidth:.infinity, maxHeight:.infinity)` cards
            // several levels deep. A flexible grid this deep makes the SwiftUI
            // layout engine re-probe every card for many candidate sizes on the
            // first build — the dominant cost when the section is rebuilt after a
            // switch. Concrete frames resolve the grid in a single pass.
            // Spacing below the 16pt grid gap: glass shapes closer than the
            // container's spacing melt into one blob, and the tiles must stay
            // discrete.
            GlassEffectContainer(spacing: 8) {
                GeometryReader { geo in
                    let columnWidth = (geo.size.width - cardGap) / 2
                    HStack(alignment: .top, spacing: cardGap) {
                        tileView(tiles[0])
                            .frame(width: columnWidth, height: geo.size.height)
                        rightColumn(
                            Array(tiles.dropFirst()),
                            width: columnWidth,
                            height: geo.size.height
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Renders one selected tile: the live malware scan, a privacy finding, or a
    /// reassurance backfill.
    @ViewBuilder
    private func tileView(_ tile: ProtectionDashboardTile) -> some View {
        switch tile {
        case .malware:                  malwareTile
        case .privacy(let privacyTile): privacyCard(privacyTile)
        case .reassurance(let content): ReassuranceCard(content: content, accent: accent)
        }
    }

    /// Ordered pool of "all good" cards, drawn from in order to backfill the grid
    /// to its minimum count when a scan finds no privacy items to clear.
    private static let reassurancePool: [ReassuranceContent] = [
        ReassuranceContent(
            id: "protection.privacyClean",
            title: String(localized: "Privacy Is Clear", comment: "Protection reassurance card title."),
            detail: String(
                localized: "No browsing data or recent-item traces stood out to clean up.",
                comment: "Protection reassurance card detail."
            ),
            icon: "hand.raised"
        ),
        ReassuranceContent(
            id: "protection.protected",
            title: String(localized: "You're Protected", comment: "Protection reassurance card title."),
            detail: String(
                localized: "Re-scan any time to keep checking for threats and privacy traces.",
                comment: "Protection reassurance card detail."
            ),
            icon: "shield.lefthalf.filled"
        ),
    ]

    private var malwareTile: some View {
        ProtectionMalwareTile(
            malware: malware,
            accent: accent,
            onStop: { malware.cancel() },
            onScanAgain: { malware.beginScan() },
            onReview: { reviewingThreats = true },
            onRemove: { confirmingMalwareRemoval = true }
        )
    }

    /// The non-hero cards, packed into rows of at most two so the column never
    /// grows taller than the pane — exactly the Applications dashboard shape.
    private func rightColumn(
        _ tiles: [ProtectionDashboardTile],
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let cardRows = rows(of: tiles)
        let rowHeight = (height - cardGap * CGFloat(cardRows.count - 1)) / CGFloat(max(cardRows.count, 1))
        return VStack(spacing: cardGap) {
            ForEach(cardRows) { row in
                let cardWidth = (width - cardGap * CGFloat(row.tiles.count - 1)) / CGFloat(row.tiles.count)
                HStack(spacing: cardGap) {
                    ForEach(row.tiles) { tile in
                        tileView(tile)
                            .frame(width: cardWidth, height: rowHeight)
                    }
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func privacyCard(_ tile: PrivacyTile) -> some View {
        ProtectionPrivacyTile(
            title: tile.title,
            metric: tile.metric,
            caption: tile.caption,
            systemImage: tile.systemImage,
            onReview: reviewAction(for: tile.removal),
            onRemove: { pendingPrivacyRemoval = tile.removal }
        )
        .accessibilityIdentifier("protection.privacyTile.\(tile.id)")
    }

    /// A browser's tile opens the manager on that browser. Recent Items has no
    /// pane to open on, so its tile offers no Review.
    private func reviewAction(for removal: PrivacyRemoval) -> (() -> Void)? {
        switch removal {
        case .browser(let browser): return { openManager(focusing: .browser(browser)) }
        case .recents: return nil
        }
    }

    /// One row of right-column cards.
    private struct TileRow: Identifiable {
        let id: Int
        let tiles: [ProtectionDashboardTile]
    }

    /// Chunks the right-column tiles into rows of two. An odd count leads with a
    /// single full-width row (matching the Applications / My Clutter shape).
    private func rows(of tiles: [ProtectionDashboardTile]) -> [TileRow] {
        var rows: [TileRow] = []
        var remaining = tiles
        if remaining.count % 2 == 1 {
            rows.append(TileRow(id: 0, tiles: [remaining.removeFirst()]))
        }
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(2))
            remaining.removeFirst(chunk.count)
            rows.append(TileRow(id: rows.count, tiles: chunk))
        }
        return rows
    }

    // MARK: - Privacy tiles model

    /// One card on the Protection dashboard: the live malware scan, a privacy
    /// finding, or an "all good" reassurance card used to backfill the grid to
    /// its minimum count.
    private enum ProtectionDashboardTile: Identifiable {
        case malware
        case privacy(PrivacyTile)
        case reassurance(ReassuranceContent)

        var id: String {
            switch self {
            case .malware:                  return "malware"
            case .privacy(let tile):        return "privacy.\(tile.id)"
            case .reassurance(let content): return "reassurance.\(content.id)"
            }
        }
    }

    /// One privacy tile derived from the privacy preview. Browser tiles carry a
    /// size metric; the recent-items tile is a single fixed entry.
    private struct PrivacyTile: Identifiable {
        let id: String
        let title: String
        let metric: String?
        let caption: String
        let systemImage: String
        let removal: PrivacyRemoval
        /// Reclaimable size in bytes used to rank the tiles; `0` for the
        /// recent-items tile, which carries no size metric.
        let bytes: Int64
    }

    /// Tiles to render: one per detected browser with something left to remove,
    /// plus Recent Items when there are any. Both come straight from the data, so
    /// a removal retires its tile and a new scan brings it back only if there's
    /// something new.
    private var privacyTiles: [PrivacyTile] {
        guard case .preview = privacy.phase else { return [] }
        var tiles: [PrivacyTile] = []
        for browser in privacy.detectedBrowsers where viewModel.hasRemovablePrivacyData(for: browser) {
            let size = privacy.removableSize(for: browser)
            tiles.append(PrivacyTile(
                id: "browser.\(browser.rawValue)",
                title: String(
                    localized: "\(browser.displayName) Browsing Data Found",
                    comment: "Protection privacy tile title for a browser's data."
                ),
                metric: size > 0 ? formattedFileBytes(size) : nil,
                caption: String(localized: "Remove your browser data to free up space and improve your privacy.",
                                comment: "Protection browser-data tile caption."),
                systemImage: "globe",
                removal: .browser(browser),
                bytes: size
            ))
        }
        if privacy.hasRecentItems {
            tiles.append(PrivacyTile(
                id: "recents",
                title: String(localized: "Recent Items Found",
                              comment: "Protection privacy tile title for recent items."),
                metric: nil,
                caption: String(localized: "Remove the traces of your recent activities by cleaning up these lists.",
                                comment: "Protection recent-items tile caption."),
                systemImage: "list.bullet.rectangle",
                removal: .recents,
                bytes: 0
            ))
        }
        return tiles
    }

    // MARK: - Removal

    /// What a privacy tile's Remove acts on.
    enum PrivacyRemoval: Identifiable {
        case browser(Browser)
        case recents

        var id: String {
            switch self {
            case .browser(let b): return "browser.\(b.rawValue)"
            case .recents: return "recents"
            }
        }
    }

    /// Says exactly what goes and what stays, because a tile's Remove acts on a
    /// whole browser with nothing ticked to look at first.
    private func confirmationMessage(for removal: PrivacyRemoval) -> String {
        switch removal {
        case .browser(let browser):
            return viewModel.protectionPrivacy.removalConfirmation(for: browser)
        case .recents:
            return String(
                localized: "This clears your Mac's recent items lists. This cannot be undone.",
                comment: "Confirmation body for removing recent items from their dashboard tile."
            )
        }
    }

    /// A tile leaves on its own once its data is gone. A failure, or a browser
    /// that has to quit first, keeps it and raises an alert from the host.
    private func performPrivacyRemoval(_ removal: PrivacyRemoval) {
        Task {
            switch removal {
            case .browser(let browser):
                _ = await viewModel.clearPrivacyData(for: browser)
            case .recents:
                _ = await viewModel.clearRecentItems()
            }
        }
    }

    @ViewBuilder
    private var threatsReviewSheet: some View {
        if case .results(let threats) = malware.phase {
            VStack(spacing: 0) {
                MalwareResultsState(
                    threats: threats,
                    onRemoveAll: {
                        confirmRemovalAfterReview = true
                        reviewingThreats = false
                    }
                )
                HStack {
                    Spacer()
                    Button(String(localized: "Close", comment: "Closes the detected-threats review without removing anything.")) {
                        reviewingThreats = false
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("malware.review.close")
                }
                .padding([.horizontal, .bottom], 24)
            }
            .frame(minWidth: 520, minHeight: 420)
        } else {
            // Threats already removed/cleared while the sheet was opening.
            Color.clear
                .frame(width: 360, height: 200)
                .onAppear { reviewingThreats = false }
        }
    }
}

/// Surfaces `removalFailureMessage` as an alert. That optional is the one
/// source of truth for whether the alert is up — the `isPresented` Bool it
/// needs is derived from it rather than tracked separately, so there is no
/// separate Bool for the two to drift out of sync on.
private struct RemovalFailureAlert: ViewModifier {
    let viewModel: ProtectionDashboardViewModel

    private var title: String {
        String(localized: "Couldn't remove these items",
               comment: "Title of the alert shown when a privacy tile's removal fails.")
    }

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(
                get: { viewModel.removalFailureMessage != nil },
                set: { if !$0 { viewModel.dismissRemovalFailure() } }
            )
        ) {
            Button(String(localized: "OK", comment: "Dismisses the privacy removal failure alert.")) {
                viewModel.dismissRemovalFailure()
            }
        } message: {
            if let message = viewModel.removalFailureMessage {
                Text(message)
            }
        }
    }
}

/// Raised when a removal is refused because its browser is open.
private struct RunningBrowserAlert: ViewModifier {
    let model: ProtectionPrivacyModel

    private var browserName: String { model.blockedByRunningBrowser?.displayName ?? "" }

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "Quit \(browserName) first", comment: "Running-browser block title."),
            isPresented: Binding(
                get: { model.blockedByRunningBrowser != nil },
                set: { if !$0 { model.acknowledgeBlock() } }
            )
        ) {
            Button(String(localized: "OK", comment: "Acknowledge.")) {
                model.acknowledgeBlock()
            }
        } message: {
            Text(String(
                localized: "These items are stored in a database \(browserName) has open. Quit \(browserName) and try again.",
                comment: "Running-browser block body."
            ))
        }
    }
}
