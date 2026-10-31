// PerformanceDashboardSubviews.swift
// Performance dashboard (hero + Login Items / Background Items summary cards) and the Performance Manager opened from "View All Tasks" — checkbox lists with Select / search and a destructive Remove, plus the maintenance-task list.

import AppKit
import SwiftUI
import VaderCleanerCore

// MARK: - Dashboard

/// The Performance landing surface (the ready state): the section hero, the
/// tagline, a "View All Tasks" button that opens the Performance Manager, and
/// two summary cards — Login Items and Background Items — each deep-linking
/// into the manager at its pane via "Review".
struct PerformanceDashboardView: View {
    let loginItemCount: Int
    /// Bundle ids of the login items, used to draw their real app icons on the
    /// Login Items summary card.
    let loginItemBundleIDs: [String]
    let backgroundItemCount: Int
    /// Number of due maintenance-cocktail tasks — drives the Maintenance card.
    let maintenanceTasksDue: Int
    /// Section accent, used to tint any reassurance backfill cards.
    let accent: Color
    let onViewAllTasks: () -> Void
    let onReviewLoginItems: () -> Void
    let onReviewBackgroundItems: () -> Void
    let onReviewMaintenance: () -> Void

    /// One card on the Performance dashboard: a summary of a category with
    /// findings, or an "all good" reassurance card used to backfill the row to
    /// its minimum count.
    private enum Tile: Identifiable {
        case loginItems
        case backgroundItems
        case maintenance
        case reassurance(ReassuranceContent)

        var id: String {
            switch self {
            case .loginItems:               return "loginItems"
            case .backgroundItems:          return "backgroundItems"
            case .maintenance:              return "maintenance"
            case .reassurance(let content): return "reassurance.\(content.id)"
            }
        }
    }

    /// The ranked 2–4 summary cards this state warrants: only the categories
    /// with findings appear, backfilled with reassurance cards when fewer than
    /// two have anything to review.
    private var tiles: [Tile] {
        var real: [RankedTile<Tile>] = []
        if loginItemCount > 0 {
            real.append(RankedTile(payload: .loginItems, urgency: .attention, reclaimableBytes: 0))
        }
        if backgroundItemCount > 0 {
            real.append(RankedTile(payload: .backgroundItems, urgency: .attention, reclaimableBytes: 0))
        }
        if maintenanceTasksDue > 0 {
            real.append(RankedTile(payload: .maintenance, urgency: .attention, reclaimableBytes: 0))
        }
        let reassurance = Self.reassurance(forFindingCount: real.count).map { content in
            RankedTile(payload: Tile.reassurance(content), urgency: .reassurance, reclaimableBytes: 0)
        }
        return SectionRecommendationSelector.select(real: real, reassurance: reassurance)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            hero
            Spacer(minLength: 0)
            summaryCards
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("performance.dashboard")
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image("performance")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 140, maxHeight: 140)
                .accessibilityHidden(true)

            Text(String(
                localized: "Apply curated recommendations\nor run performance tasks manually.",
                comment: "Performance dashboard tagline."
            ))
            .font(.title.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)

            Button(action: onViewAllTasks) {
                Text(String(
                    localized: "View All Tasks",
                    comment: "Button that opens the full Performance Manager."
                ))
                .padding(.horizontal, 8)
            }
            .buttonStyle(.vaderTileGlass)
            .controlSize(.large)
            .accessibilityIdentifier("performance.viewAllTasks")
        }
    }

    /// The ranked summary cards along the bottom, refracting together in one
    /// glass container so they read as a set.
    private var summaryCards: some View {
        // Spacing below the 16pt grid gap so adjacent tiles never blend.
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 16) {
                ForEach(tiles) { tile in
                    card(tile)
                }
            }
        }
        .frame(height: 200)
    }

    /// Renders one ranked summary card, or a reassurance backfill.
    @ViewBuilder
    private func card(_ tile: Tile) -> some View {
        switch tile {
        case .loginItems:
            PerformanceSummaryCard(
                title: loginItemsTitle,
                description: String(
                    localized: "Review the list of applications that open automatically when you start up your Mac. You may want to disable some of them.",
                    comment: "Login Items summary card description."
                ),
                accessory: .appIcons(loginItemBundleIDs),
                reviewIdentifier: "performance.reviewLoginItems",
                onReview: onReviewLoginItems
            )
        case .backgroundItems:
            PerformanceSummaryCard(
                title: backgroundItemsTitle,
                description: String(
                    localized: "Review the processes and apps that run in the background. You may not need or want part of them.",
                    comment: "Background Items summary card description."
                ),
                accessory: .badge(symbol: "gearshape.2.fill", tint: Color(red: 0.96, green: 0.55, blue: 0.30)),
                reviewIdentifier: "performance.reviewBackgroundItems",
                onReview: onReviewBackgroundItems
            )
        case .maintenance:
            PerformanceSummaryCard(
                title: maintenanceTitle,
                description: String(
                    localized: "Run the due maintenance tasks to keep your Mac in shape — rebuilding caches and tidying system housekeeping.",
                    comment: "Maintenance summary card description."
                ),
                accessory: .badge(symbol: "wrench.and.screwdriver.fill", tint: accent),
                reviewIdentifier: "performance.reviewMaintenance",
                onReview: onReviewMaintenance
            )
        case .reassurance(let content):
            ReassuranceCard(content: content, accent: accent)
        }
    }

    /// The "all good" cards available for backfilling. "Running Smoothly" says
    /// nothing needs attention, which is only true with no findings at all; it
    /// must not sit beside a card asking for a review.
    static func reassurance(forFindingCount count: Int) -> [ReassuranceContent] {
        count == 0 ? reassurancePool : reassurancePool.filter { $0.id != "performance.tuned" }
    }

    /// Ordered pool of "all good" cards, drawn from in order when fewer than two
    /// categories have anything to review so backfilling never repeats a card.
    private static let reassurancePool: [ReassuranceContent] = [
        ReassuranceContent(
            id: "performance.tuned",
            title: String(localized: "Running Smoothly", comment: "Performance reassurance card title."),
            detail: String(
                localized: "No login items, background items, or maintenance tasks need your attention.",
                comment: "Performance reassurance card detail."
            ),
            icon: "gauge.with.needle"
        ),
        ReassuranceContent(
            id: "performance.allTasks",
            title: String(localized: "Fine-Tune Anytime", comment: "Performance reassurance card title."),
            detail: String(
                localized: "Open View All Tasks to run maintenance or review startup items whenever you like.",
                comment: "Performance reassurance card detail."
            ),
            icon: "slider.horizontal.3"
        ),
    ]

    private var loginItemsTitle: String { Self.loginItemsTitle(count: loginItemCount) }
    private var backgroundItemsTitle: String { Self.backgroundItemsTitle(count: backgroundItemCount) }
    private var maintenanceTitle: String { Self.maintenanceTitle(count: maintenanceTasksDue) }

    static func loginItemsTitle(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "You Have %lld Login Items", comment: "Login Items summary card title; %lld is the count."),
            count
        )
    }

    static func backgroundItemsTitle(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "%lld Background Items Found", comment: "Background Items summary card title; %lld is the count."),
            count
        )
    }

    static func maintenanceTitle(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "%lld Maintenance Tasks Recommended", comment: "Maintenance summary card title; %lld is the count."),
            count
        )
    }
}

/// A Performance dashboard summary card: a title, a one-line description, a
/// top-right accessory (a cluster of app icons or a tinted badge), and a
/// bottom-right "Review" button. Uses the same glass surface and corner radius
/// as the app's other dashboard cards so the surfaces stay consistent.
struct PerformanceSummaryCard: View {
    /// The card's top-right accessory.
    enum Accessory {
        /// Up to a few real app icons, drawn from the given bundle ids.
        case appIcons([String])
        /// A single tinted SF Symbol badge.
        case badge(symbol: String, tint: Color)
    }

    let title: String
    let description: String
    let accessory: Accessory
    let reviewIdentifier: String
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                accessoryView
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack {
                Spacer()
                Button(action: onReview) {
                    Text(String(localized: "Review", comment: "Summary card button that opens the manager at this card's items."))
                }
                .buttonStyle(.vaderGlass)
                .accessibilityIdentifier(reviewIdentifier)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .vaderTileGlass()
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .appIcons(let bundleIDs):
            AppIconCluster(bundleIDs: bundleIDs)
        case .badge(let symbol, let tint):
            TaskIconBadge(symbol: symbol, tint: tint)
        }
    }
}

/// A small cluster of overlapping real app icons, resolved from bundle ids. Caps
/// the count so a long list still reads as a tidy stack.
struct AppIconCluster: View {
    let bundleIDs: [String]

    // Resolved once per `bundleIDs` rather than on every render: the lookup does
    // a synchronous LaunchServices query per id, and this cluster sits on the
    // Performance dashboard whose live stats re-render the parent frequently.
    @State private var icons: [NSImage] = []

    var body: some View {
        Group {
            if icons.isEmpty {
                TaskIconBadge(symbol: "person.crop.circle.badge.checkmark", tint: Color(red: 0.55, green: 0.45, blue: 0.95))
            } else {
                HStack(spacing: -12) {
                    ForEach(Array(icons.enumerated()), id: \.offset) { _, icon in
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 40, height: 40)
                    }
                }
            }
        }
        .task(id: bundleIDs) { resolveIcons() }
    }

    private func resolveIcons() {
        icons = bundleIDs.prefix(3).compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }
}

// MARK: - Performance Manager

/// The standalone Performance Manager (opened from "View All Tasks" or a
/// dashboard card's "Review"), styled like the Cleanup Manager: a white,
/// light-mode card with the magenta accent, a Back / search header, a left
/// navigation (Login Items / Background Items / Maintenance Tasks), and a
/// detail pane. Login Items and Background Items are checkbox lists with a
/// `Select:` menu and a destructive **Remove** footer; Maintenance Tasks keeps
/// its multi-select **Run** bar.
///
/// Remove is backed by what macOS truthfully allows (`removeSelected`): a login
/// item is unregistered, a user launch agent is stopped and its plist moved to
/// the Trash. Items installed for all users live in launchd's privileged domain,
/// so they are listed for review but never offered for removal. Selected rows a
/// search is hiding are out of reach of every bulk action
/// (`PerformanceManagerListing`), so what the footer counts is what gets acted on.
struct PerformanceTaskCatalogView: View {

    /// The three panes the left navigation switches between.
    enum Pane: Hashable {
        case maintenanceTasks
        case loginItems
        case backgroundItems
    }

    /// Which pane is shown. Bound to the owning view so a dashboard card can open
    /// a specific pane.
    @Binding var pane: Pane
    /// Selected maintenance-task ids, bound to the owning view so the Maintenance
    /// card's Review can preselect what is due.
    @Binding var selectedTaskIDs: Set<String>
    let tasks: [MaintenanceTask]
    /// Ids of the tasks due to run again, marked on their rows.
    let dueTaskIDs: Set<String>
    let results: [String: String]
    let loginItems: [LoginItem]
    let userAgents: [LaunchAgent]
    let systemAgents: [LaunchAgent]
    let onRunSelected: ([MaintenanceTask]) -> Void
    /// Removes the current selection: `loginItemIDs` are unregistered and
    /// `agentIDs` (user agents only) are stopped and moved to the Trash.
    let onRemoveSelected: (_ loginItemIDs: Set<String>, _ agentIDs: Set<String>) -> Void
    let onSetAgentEnabled: (LaunchAgent, Bool) -> Void
    let onOpenLoginItemsSettings: () -> Void
    let onBack: () -> Void

    /// Checkbox selection for the Login Items and Background Items panes. Held
    /// here (not on the owning view) because it is a within-manager concern. Rows
    /// that leave the list leave the selection, so after a Remove what is still
    /// ticked is exactly what failed, ready for a retry.
    @State private var selectedLoginIDs: Set<String> = []
    @State private var selectedAgentIDs: Set<String> = []
    @State private var search = ""
    @State private var confirmRemove = false

    // The Login Items and Background Items rows, mapped once from the inputs and
    // memoized. The login mapping does a synchronous LaunchServices lookup per
    // item, so rebuilding it on every render — e.g. each checkbox toggle — was a
    // real cost; recompute only when the underlying items change.
    @State private var loginManagerItems: [ManagerItem] = []
    @State private var agentManagerItems: [ManagerItem] = []
    @State private var systemAgentManagerItems: [ManagerItem] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                navigationPane
                Divider().opacity(0.4)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ManagerSurfaceModifier(light: true))
        .tint(ManagerChrome.accent)
        .environment(\.sectionAccent, ManagerChrome.accent)
        .accessibilityIdentifier("performance.catalog")
        // Build the row models once, and again only when the inputs change, so
        // the per-item LaunchServices lookup never runs during an ordinary
        // re-render such as a checkbox toggle.
        .onAppear {
            recomputeLoginManagerItems()
            recomputeAgentManagerItems()
            recomputeSystemAgentManagerItems()
        }
        .onChange(of: loginItems) { _, _ in recomputeLoginManagerItems() }
        .onChange(of: userAgents) { _, _ in recomputeAgentManagerItems() }
        .onChange(of: systemAgents) { _, _ in recomputeSystemAgentManagerItems() }
        // A search belongs to the list it was typed over, so it never carries
        // into another pane and turns that one up empty.
        .onChange(of: pane) { _, _ in search = "" }
        .alert(
            String(localized: "Remove the selected items?", comment: "Title of the Performance Manager remove confirmation."),
            isPresented: $confirmRemove
        ) {
            Button(String(localized: "Cancel", comment: "Cancel button on the Performance Manager remove confirmation."), role: .cancel) {}
            Button(String(localized: "Remove", comment: "Confirm button on the Performance Manager remove confirmation."), role: .destructive) {
                performRemove()
            }
        } message: {
            Text(removeConfirmationMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                search = ""
                onBack()
            } label: {
                // HStack(Image, Text) rather than Label so the control surfaces
                // reliably in XCUITest.
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").foregroundStyle(.tint)
                    Text(String(localized: "Back", comment: "Back button returning from the Performance Manager to the dashboard."))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("performance.backToDashboard")

            Spacer()
            Text(String(localized: "Performance Manager", comment: "Title of the Performance Manager screen."))
                .font(.headline)
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tint)
                TextField(
                    String(localized: "Search", comment: "Placeholder in the Performance Manager search field."),
                    text: $search
                )
                .textFieldStyle(.plain)
                .frame(width: 140)
                .accessibilityIdentifier("performance.manager.search")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: Navigation

    private var navigationPane: some View {
        ScrollView {
            VStack(spacing: 4) {
                navItem(.loginItems,
                        String(localized: "Login Items", comment: "Performance Manager nav item."),
                        "performance.manager.nav.loginItems")
                navItem(.backgroundItems,
                        String(localized: "Background Items", comment: "Performance Manager nav item."),
                        "performance.manager.nav.backgroundItems")
                navItem(.maintenanceTasks,
                        String(localized: "Maintenance Tasks", comment: "Performance Manager nav item."),
                        "performance.manager.nav.maintenanceTasks")
                Spacer()
            }
            .padding(8)
        }
        .frame(width: 220)
    }

    private func navItem(_ target: Pane, _ title: String, _ identifier: String) -> some View {
        NavRow(selected: pane == target) {
            pane = target
        } content: {
            Text(title).font(.body.weight(.medium))
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        switch pane {
        case .maintenanceTasks:
            maintenanceTasksPane
        case .loginItems:
            itemListPane(
                paneKey: "loginItems",
                title: String(localized: "Login Items", comment: "Performance Manager Login Items pane title."),
                description: String(
                    localized: "Manage the list of applications that get automatically opened every time you log in. Don't make your Mac waste its performance on the processes you don't need.",
                    comment: "Performance Manager Login Items pane description."
                ),
                items: loginManagerItems,
                selection: $selectedLoginIDs
            )
        case .backgroundItems:
            itemListPane(
                paneKey: "backgroundItems",
                title: String(localized: "Background Items", comment: "Performance Manager Background Items pane title."),
                description: String(
                    localized: "Manage the list of processes and applications that run in the background. You may not need or want part of them.",
                    comment: "Performance Manager Background Items pane description."
                ),
                items: agentManagerItems,
                selection: $selectedAgentIDs,
                reviewOnlyItems: systemAgentManagerItems
            )
        }
    }

    /// A checkbox list pane (Login Items / Background Items), laid out like the
    /// Maintenance Tasks pane: a heading, a one-line description, a `Select:`
    /// menu, the card rows, and any rows that are listed for review only.
    @ViewBuilder
    private func itemListPane(
        paneKey: String,
        title: String,
        description: String,
        items: [ManagerItem],
        selection: Binding<Set<String>>,
        reviewOnlyItems: [ManagerItem] = []
    ) -> some View {
        let displayed = PerformanceManagerListing.items(items, matching: search)
        let displayedReviewOnly = PerformanceManagerListing.items(reviewOnlyItems, matching: search)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title3.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                selectRow(paneKey: paneKey, visibleIDs: displayed.map(\.id), selection: selection)
                if displayed.isEmpty && displayedReviewOnly.isEmpty {
                    emptyState(isFiltering: !search.isEmpty)
                } else if !displayed.isEmpty {
                    // Lazy because the background-items pane is as long as the
                    // machine says: `launchctl list` runs to several hundred
                    // entries on a developer's Mac, and an eagerly-built stack
                    // of 500 rows costs ~100ms of layout on every pass — which
                    // the search field and sort control both trigger.
                    LazyVStack(spacing: 10) {
                        ForEach(displayed) { item in
                            PerformanceItemRow(
                                item: item,
                                isSelected: selection.wrappedValue.contains(item.id),
                                identifier: "performance.manager.\(paneKey).item.\(item.id)",
                                control: control(for: item),
                                onToggle: { toggle(item.id, in: selection) }
                            )
                        }
                    }
                }
                if !displayedReviewOnly.isEmpty {
                    reviewOnlySection(paneKey: paneKey, items: displayedReviewOnly)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private func emptyState(isFiltering: Bool) -> some View {
        Text(isFiltering
            ? String(localized: "Nothing matches your search", comment: "Empty state in a Performance Manager pane when a search hides every row.")
            : String(localized: "Nothing to review", comment: "Empty state in a Performance Manager pane."))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
    }

    /// The items installed for all users. VaderCleaner can't safely remove what
    /// another app put in launchd's privileged domain, but they are real and
    /// running, so they're shown rather than just counted, with the place macOS
    /// lets them be changed.
    private func reviewOnlySection(paneKey: String, items: [ManagerItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Installed for All Users", comment: "Heading above the Background Items VaderCleaner lists but doesn't remove."))
                .font(.headline)
                .padding(.top, 8)
            HStack(spacing: 12) {
                Text(String(
                    localized: "These were installed by other apps. You can turn them off in System Settings, or remove them by uninstalling the app they came with.",
                    comment: "Explains the Background Items VaderCleaner lists but doesn't remove."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(String(localized: "Open System Settings", comment: "Opens System Settings to Login Items & Extensions from the Performance Manager."), action: onOpenLoginItemsSettings)
                    .accessibilityIdentifier("performance.manager.\(paneKey).openSettings")
            }
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    PerformanceItemRow(
                        item: item,
                        isSelected: false,
                        identifier: "performance.manager.\(paneKey).reviewOnly.\(item.id)",
                        control: .none,
                        onToggle: {}
                    )
                }
            }
        }
    }

    /// The control a row carries beyond its checkbox: an on/off switch for a user
    /// agent with a job to run, and a way to finish a pending login item.
    private func control(for item: ManagerItem) -> PerformanceItemRow.Control {
        if let agent = userAgents.first(where: { $0.id == item.id }) {
            // An orphaned plist defines nothing to run, so its switch would be dead.
            guard !agent.isOrphaned else { return .none }
            return .toggle(
                isOn: agent.isEnabled,
                identifier: "performance.manager.agentToggle.\(agent.label)",
                action: { onSetAgentEnabled(agent, $0) }
            )
        }
        if loginItems.first(where: { $0.id == item.id })?.requiresApproval == true {
            return .openSettings(action: onOpenLoginItemsSettings)
        }
        return .none
    }

    /// The `Select:` bulk-select menu, scoped to the rows on screen.
    private func selectRow(paneKey: String, visibleIDs: [String], selection: Binding<Set<String>>) -> some View {
        let selectedCount = PerformanceManagerListing.actionableSelection(
            selection.wrappedValue, visibleIDs: visibleIDs
        ).count
        return HStack(spacing: 8) {
            Text(String(localized: "Select:", comment: "Label before the bulk-select menu on the Performance Manager."))
                .foregroundStyle(.secondary)
            Menu {
                Button(String(localized: "Select All", comment: "Bulk-select every item in the pane.")) {
                    selection.wrappedValue = PerformanceManagerListing.selectingAll(
                        in: selection.wrappedValue, visibleIDs: visibleIDs
                    )
                }
                .disabled(selectedCount == visibleIDs.count || visibleIDs.isEmpty)
                Button(String(localized: "Deselect All", comment: "Bulk-deselect every item in the pane.")) {
                    selection.wrappedValue = PerformanceManagerListing.deselectingAll(
                        in: selection.wrappedValue, visibleIDs: visibleIDs
                    )
                }
                .disabled(selectedCount == 0)
            } label: {
                Text(bulkSelectLabel(selected: selectedCount, total: visibleIDs.count))
                    .foregroundStyle(.tint)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("performance.manager.\(paneKey).select")
            Spacer()
        }
        .font(.callout)
    }

    private var maintenanceTasksPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Maintenance Tasks", comment: "Maintenance tasks pane heading."))
                    .font(.title3.weight(.semibold))
                Text(String(
                    localized: "Essential Mac care, run in one place. Select the tasks you want and run them together.",
                    comment: "Maintenance tasks pane description."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)

                if displayedTasks.isEmpty {
                    emptyState(isFiltering: !search.isEmpty)
                } else {
                    VStack(spacing: 10) {
                        ForEach(displayedTasks) { task in
                            PerformanceTaskRow(
                                task: task,
                                tint: PerformanceTaskPalette.tint(for: task.kind),
                                isSelected: selectedTaskIDs.contains(task.id),
                                isDue: dueTaskIDs.contains(task.id),
                                result: results[task.id],
                                onToggle: { toggleTask(task) }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch pane {
        case .maintenanceTasks:
            runFooter
        case .loginItems:
            removeFooter(selectedCount: currentPaneSelectedCount)
        case .backgroundItems:
            removeFooter(selectedCount: currentPaneSelectedCount)
        }
    }

    private var runFooter: some View {
        HStack(spacing: 12) {
            Text(tasksSelectedSummary)
                .font(.callout.weight(.medium))
            Spacer()
            Button(String(localized: "Run", comment: "Runs the selected maintenance tasks.")) {
                onRunSelected(tasks.filter { runnableTaskIDs.contains($0.id) })
            }
            .buttonStyle(.vaderProminent)
            .disabled(runnableTaskIDs.isEmpty)
            .accessibilityIdentifier("performance.runSelected")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func removeFooter(selectedCount: Int) -> some View {
        HStack(spacing: 12) {
            Text(itemsSelectedSummary(selectedCount))
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("performance.manager.summary")
            Spacer()
            Button(String(localized: "Remove", comment: "Footer button removing the selected items in the Performance Manager."), role: .destructive) {
                confirmRemove = true
            }
            .buttonStyle(.borderedProminent)
            .tint(ManagerChrome.accent)
            .disabled(selectedCount == 0)
            .accessibilityIdentifier("performance.manager.remove")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Item models

    private func recomputeLoginManagerItems() {
        loginManagerItems = loginItems.map { item in
            let iconPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.id)?.path
            return ManagerItem(
                id: item.id,
                title: item.name,
                subtitle: loginSubtitle(item),
                size: nil,
                sizeText: nil,
                systemImage: "power",
                tint: .orange,
                usesFileIcon: iconPath != nil,
                iconPath: iconPath
            )
        }
        selectedLoginIDs.formIntersection(loginItems.map(\.id))
    }

    private func recomputeAgentManagerItems() {
        agentManagerItems = userAgents.map { agent in
            ManagerItem(
                id: agent.id,
                title: agent.label,
                subtitle: agent.programPath ?? agent.path.path,
                size: nil,
                sizeText: nil,
                systemImage: "gearshape",
                tint: .secondary,
                usesFileIcon: true,
                iconPath: agentIconPath(agent)
            )
        }
        selectedAgentIDs.formIntersection(userAgents.map(\.id))
    }

    private func recomputeSystemAgentManagerItems() {
        systemAgentManagerItems = systemAgents.map { agent in
            ManagerItem(
                id: agent.id,
                title: agent.label,
                subtitle: agent.programPath ?? agent.path.path,
                size: nil,
                sizeText: nil,
                systemImage: "gearshape",
                tint: .secondary,
                usesFileIcon: true,
                isLocked: true,
                iconPath: agentIconPath(agent)
            )
        }
    }

    private func loginSubtitle(_ item: LoginItem) -> String {
        if item.requiresApproval {
            return String(
                localized: "Waiting for your approval",
                comment: "Login-item subtitle when the registration awaits the user's approval."
            )
        }
        return String(localized: "Enabled", comment: "Login-item subtitle when it opens at login.")
    }

    /// The icon source for an agent row: its program's app bundle when the
    /// program lives inside one (so updaters show the parent app's icon), else
    /// the plist itself (a generic .plist document icon, as in the reference).
    private func agentIconPath(_ agent: LaunchAgent) -> String {
        agent.appBundlePath ?? agent.path.path
    }

    // MARK: - Derived data

    private var displayedTasks: [MaintenanceTask] {
        PerformanceManagerListing.tasks(tasks, matching: search)
    }

    /// The ticked tasks on screen — what Run reaches.
    private var runnableTaskIDs: Set<String> {
        PerformanceManagerListing.actionableSelection(selectedTaskIDs, visibleIDs: displayedTasks.map(\.id))
    }

    /// The ticked login items on screen — what Remove reaches on that pane.
    private var removableLoginIDs: Set<String> {
        PerformanceManagerListing.actionableSelection(
            selectedLoginIDs,
            visibleIDs: PerformanceManagerListing.items(loginManagerItems, matching: search).map(\.id)
        )
    }

    /// The ticked background items on screen — what Remove reaches on that pane.
    private var removableAgentIDs: Set<String> {
        PerformanceManagerListing.actionableSelection(
            selectedAgentIDs,
            visibleIDs: PerformanceManagerListing.items(agentManagerItems, matching: search).map(\.id)
        )
    }

    private var currentPaneSelectedCount: Int {
        switch pane {
        case .loginItems:      return removableLoginIDs.count
        case .backgroundItems: return removableAgentIDs.count
        case .maintenanceTasks: return 0
        }
    }

    // MARK: - Actions

    private func toggle(_ id: String, in selection: Binding<Set<String>>) {
        if selection.wrappedValue.contains(id) {
            selection.wrappedValue.remove(id)
        } else {
            selection.wrappedValue.insert(id)
        }
    }

    private func toggleTask(_ task: MaintenanceTask) {
        if selectedTaskIDs.contains(task.id) {
            selectedTaskIDs.remove(task.id)
        } else {
            selectedTaskIDs.insert(task.id)
        }
    }

    /// Routes the confirmed Remove to the current pane's selection so each pane
    /// removes exactly what it shows. The selection stays: rows that go take their
    /// ticks with them, and rows that fail stay ticked for a retry.
    private func performRemove() {
        switch pane {
        case .loginItems:
            onRemoveSelected(removableLoginIDs, [])
        case .backgroundItems:
            onRemoveSelected([], removableAgentIDs)
        case .maintenanceTasks:
            break
        }
    }

    // MARK: - Footer text

    private var tasksSelectedSummary: String {
        String.localizedStringWithFormat(
            String(localized: "%lld Tasks Selected", comment: "Footer count of selected maintenance tasks."),
            runnableTaskIDs.count
        )
    }

    private func itemsSelectedSummary(_ count: Int) -> String {
        count == 0
            ? String(localized: "No Items Selected", comment: "Performance Manager footer when nothing is selected.")
            : String.localizedStringWithFormat(
                String(localized: "%lld Items Selected", comment: "Live count of selected items in the Performance Manager footer."),
                count
            )
    }

    /// Names what will go as well as how many, so a selection made before a
    /// search can't surprise anyone.
    private var removeConfirmationMessage: String {
        switch pane {
        case .loginItems:
            let summary = String.localizedStringWithFormat(
                String(
                    localized: "%lld login items will stop opening at login:",
                    comment: "Performance Manager remove confirmation for login items, followed by their names."
                ),
                removableLoginIDs.count
            )
            return confirmationMessage(summary, items: loginManagerItems, ids: removableLoginIDs)
        case .backgroundItems:
            let summary = String.localizedStringWithFormat(
                String(
                    localized: "%lld background items will be stopped and moved to the Trash:",
                    comment: "Performance Manager remove confirmation for background items, followed by their names."
                ),
                removableAgentIDs.count
            )
            return confirmationMessage(summary, items: agentManagerItems, ids: removableAgentIDs)
        case .maintenanceTasks:
            return ""
        }
    }

    private func confirmationMessage(_ summary: String, items: [ManagerItem], ids: Set<String>) -> String {
        let names = items.filter { ids.contains($0.id) }.map(\.title)
        return summary + "\n\n" + PerformanceManagerListing.confirmationList(names: names, limit: 8)
    }

    private func bulkSelectLabel(selected: Int, total: Int) -> String {
        if selected == 0 || total == 0 {
            return String(localized: "None", comment: "Bulk-select trigger when nothing in the pane is selected.")
        }
        if selected == total {
            return String(localized: "All", comment: "Bulk-select trigger when everything in the pane is selected.")
        }
        return String(localized: "Some", comment: "Bulk-select trigger when part of the pane is selected.")
    }
}
