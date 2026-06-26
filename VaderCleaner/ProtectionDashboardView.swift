// ProtectionDashboardView.swift
// The Protection results dashboard — a live malware-scan tile beside privacy result tiles that fill in as each scan becomes ready, mirroring the CleanMyMac Protection grid.

import SwiftUI
import AppKit

/// Renders the Protection section's dashboard: a Start Over bar, a centered
/// header, and a grid whose left tile shows the live malware scan while the
/// right column fills with privacy tiles as the (faster) privacy preview
/// completes. Composes `ProtectionDashboardViewModel`'s two child flows; this
/// view owns only presentation state (which sheet/alert is up, which privacy
/// tiles the user has already removed).
struct ProtectionDashboardView: View {

    let viewModel: ProtectionDashboardViewModel

    /// Which surface the section shows: the results dashboard, or the dedicated
    /// Protection Manager opened by "Manage Privacy Items" / a card's Review.
    private enum Detail { case dashboard, manager }

    @State private var detail: Detail = .dashboard
    @State private var onboardingViewModel = MalwareOnboardingViewModel()
    @State private var reviewingThreats = false
    @State private var confirmingMalwareRemoval = false
    @State private var pendingPrivacyRemoval: PrivacyRemoval?
    @State private var removedPrivacyTiles: Set<String> = []

    /// Browser icons + resolved bundle URLs for the manager's rows, loaded the
    /// same way `PrivacyView` does.
    @State private var iconCache = AppIconCache()
    @State private var browserBundleURLs: [Browser: URL] = [:]

    private var malware: MalwareViewModel { viewModel.malware }
    private var privacy: PrivacyViewModel { viewModel.privacy }
    private let accent = NavigationSection.malwareRemoval.theme.accent

    var body: some View {
        Group {
            if detail == .manager {
                ProtectionManagerView(
                    malware: malware,
                    privacyModel: viewModel.protectionPrivacy,
                    iconCache: iconCache,
                    bundleURL: { browserBundleURLs[$0] },
                    onBack: { detail = .dashboard }
                )
            } else {
                dashboardSurface
            }
        }
        // The dashboard appears once a scan has begun. Ensure the privacy
        // preview is running too — covers the Smart Scan seed path, where
        // the dashboard shows without this view's own beginScan.
        .task {
            if privacy.phase == .idle { privacy.beginScan() }
        }
        // Resolve each detected browser's bundle URL + warm the icon cache for
        // the manager's rows, the same way PrivacyView does.
        .task(id: privacy.detectedBrowsers) { await loadBrowserIcons() }
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
            .sheet(isPresented: $reviewingThreats) {
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
                Text(String(localized: "The infected files will be permanently deleted. This cannot be undone.",
                            comment: "Body of the malware removal confirmation alert."))
            }
            .alert(item: $pendingPrivacyRemoval) { removal in
                privacyRemovalAlert(removal)
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
            detail: malwareProgressLine,
            identifier: "protection.loading",
            countDetail: ScanProgressFormatting.filesScanned(malware.scannedItemCount),
            phrases: ScanPhrases.scanning(for: .malwareRemoval),
            onCancel: { viewModel.startOver() }
        )
    }

    /// The current clamscan progress line, if the malware scan is streaming.
    private var malwareProgressLine: String? {
        if case .scanning(let progress) = malware.phase { return progress }
        return nil
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
            Button(action: { detail = .manager }) {
                Text(String(
                    localized: "Manage Privacy Items",
                    comment: "Protection dashboard button that opens the Privacy manager."
                ))
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(.white.opacity(0.15), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("protection.managePrivacy")
        }
        .padding(.top, 4)
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
    @ViewBuilder
    private var grid: some View {
        if privacyTiles.isEmpty {
            malwareTile
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GlassEffectContainer(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    malwareTile
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    rightColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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

    /// The privacy findings, packed into rows of at most two so the column never
    /// grows taller than the pane — exactly the Applications dashboard shape.
    private var rightColumn: some View {
        VStack(spacing: 16) {
            ForEach(privacyRows) { row in
                HStack(spacing: 16) {
                    ForEach(row.tiles) { tile in
                        privacyCard(tile)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func privacyCard(_ tile: PrivacyTile) -> some View {
        ProtectionPrivacyTile(
            title: tile.title,
            metric: tile.metric,
            caption: tile.caption,
            systemImage: tile.systemImage,
            onReview: { detail = .manager },
            onRemove: { pendingPrivacyRemoval = tile.removal }
        )
        .accessibilityIdentifier("protection.privacyTile.\(tile.id)")
    }

    /// One row of right-column cards.
    private struct PrivacyRow: Identifiable {
        let id: Int
        let tiles: [PrivacyTile]
    }

    /// Chunks the privacy tiles into rows of two. An odd count leads with a
    /// single full-width row (matching the Applications / My Clutter shape).
    private var privacyRows: [PrivacyRow] {
        var rows: [PrivacyRow] = []
        var remaining = privacyTiles
        if remaining.count % 2 == 1 {
            rows.append(PrivacyRow(id: 0, tiles: [remaining.removeFirst()]))
        }
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(2))
            remaining.removeFirst(chunk.count)
            rows.append(PrivacyRow(id: rows.count, tiles: chunk))
        }
        return rows
    }

    // MARK: - Privacy tiles model

    /// One privacy tile derived from the privacy preview. Browser tiles carry a
    /// size metric; the recent-items tile is a single fixed entry.
    private struct PrivacyTile: Identifiable {
        let id: String
        let title: String
        let metric: String?
        let caption: String
        let systemImage: String
        let removal: PrivacyRemoval
    }

    /// Tiles to render: one per detected browser with data, plus Recent Items —
    /// minus any the user has already removed from the grid this session.
    private var privacyTiles: [PrivacyTile] {
        guard case .preview = privacy.phase else { return [] }
        var tiles: [PrivacyTile] = []
        for browser in privacy.detectedBrowsers {
            let size = privacy.sizeOnDisk(for: browser)
            guard size > 0 else { continue }
            let id = "browser.\(browser.rawValue)"
            guard !removedPrivacyTiles.contains(id) else { continue }
            tiles.append(PrivacyTile(
                id: id,
                title: String(
                    localized: "\(browser.displayName) Browsing Data Found",
                    comment: "Protection privacy tile title for a browser's data."
                ),
                metric: smartScanByteFormatter.string(fromByteCount: size),
                caption: String(localized: "Remove your browser data to free up space and improve your privacy.",
                                comment: "Protection browser-data tile caption."),
                systemImage: "globe",
                removal: .browser(browser)
            ))
        }
        if !removedPrivacyTiles.contains("recents") {
            tiles.append(PrivacyTile(
                id: "recents",
                title: String(localized: "Recent Items Found",
                              comment: "Protection privacy tile title for recent items."),
                metric: nil,
                caption: String(localized: "Remove the traces of your recent activities by cleaning up these lists.",
                                comment: "Protection recent-items tile caption."),
                systemImage: "list.bullet.rectangle",
                removal: .recents
            ))
        }
        return tiles
    }

    // MARK: - Removal

    /// What a privacy tile's Remove acts on. `Identifiable` so it can drive an
    /// `.alert(item:)` confirmation.
    enum PrivacyRemoval: Identifiable {
        case browser(Browser)
        case recents

        var id: String {
            switch self {
            case .browser(let b): return "browser.\(b.rawValue)"
            case .recents: return "recents"
            }
        }

        var tileID: String { id }
    }

    private func privacyRemovalAlert(_ removal: PrivacyRemoval) -> Alert {
        Alert(
            title: Text(String(localized: "Remove these items?",
                               comment: "Privacy removal confirmation title.")),
            message: Text(String(localized: "This permanently deletes the selected data. This cannot be undone.",
                                 comment: "Privacy removal confirmation body.")),
            primaryButton: .destructive(
                Text(String(localized: "Remove", comment: "Confirm privacy removal."))
            ) {
                performPrivacyRemoval(removal)
            },
            secondaryButton: .cancel()
        )
    }

    private func performPrivacyRemoval(_ removal: PrivacyRemoval) {
        Task {
            do {
                switch removal {
                case .browser(let browser):
                    try await privacy.clearData(for: browser)
                case .recents:
                    try await privacy.clearRecentItems()
                }
                _ = withAnimation { removedPrivacyTiles.insert(removal.tileID) }
            } catch {
                // Best-effort: leave the tile in place so the user can retry.
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
                        reviewingThreats = false
                        confirmingMalwareRemoval = true
                    }
                )
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
