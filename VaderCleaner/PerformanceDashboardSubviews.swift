// PerformanceDashboardSubviews.swift
// Performance dashboard (hero + Login Items / Background Items summary cards) and the Performance Manager opened from "View All Tasks" — checkbox lists with Select / search / Sort and a destructive Remove, plus the maintenance-task list.

import AppKit
import SwiftUI

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
    let onViewAllTasks: () -> Void
    let onReviewLoginItems: () -> Void
    let onReviewBackgroundItems: () -> Void

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
        VStack(spacing: 16) {
            Image("performance")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 200, maxHeight: 200)
                .accessibilityHidden(true)
            Text(String(
                localized: "Apply curated recommendations\nor run performance tasks manually.",
                comment: "Performance dashboard tagline."
            ))
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

            Button(action: onViewAllTasks) {
                Text(String(
                    localized: "View All Tasks",
                    comment: "Button that opens the full Performance Manager."
                ))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("performance.viewAllTasks")
        }
    }

    /// The two summary cards along the bottom, refracting together in one glass
    /// container so they read as a pair.
    private var summaryCards: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
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
            }
        }
        .frame(height: 200)
    }

    private var loginItemsTitle: String {
        String.localizedStringWithFormat(
            String(localized: "You Have %lld Login Items", comment: "Login Items summary card title; %lld is the count."),
            loginItemCount
        )
    }

    private var backgroundItemsTitle: String {
        String.localizedStringWithFormat(
            String(localized: "%lld Background Items Found", comment: "Background Items summary card title; %lld is the count."),
            backgroundItemCount
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack {
                Spacer()
                Button(action: onReview) {
                    Text(String(localized: "Review", comment: "Summary card button that opens the manager at this card's items."))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(reviewIdentifier)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
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

    private var icons: [NSImage] {
        bundleIDs.prefix(3).compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    var body: some View {
        let resolved = icons
        if resolved.isEmpty {
            TaskIconBadge(symbol: "person.crop.circle.badge.checkmark", tint: Color(red: 0.55, green: 0.45, blue: 0.95))
        } else {
            HStack(spacing: -12) {
                ForEach(Array(resolved.enumerated()), id: \.offset) { _, icon in
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 40, height: 40)
                }
            }
        }
    }
}

// MARK: - Performance Manager

/// The standalone Performance Manager (opened from "View All Tasks" or a
/// dashboard card's "Review"), styled like the Cleanup Manager: a white,
/// light-mode card with the magenta accent, a Back / search / Sort-by header, a
/// left navigation (Login Items / Background Items / Maintenance Tasks), and a
/// detail pane. Login Items and Background Items are checkbox lists with a
/// `Select:` menu and a destructive **Remove** footer; Maintenance Tasks keeps
/// its multi-select **Run** bar.
///
/// Remove is backed by what macOS truthfully allows (`removeSelected`): a login
/// item is unregistered, a user launch agent's plist is deleted. macOS‑managed
/// daemons can't be enumerated/removed via `SMAppService`, so they are noted but
/// never offered for removal — matching the reference's third‑party list.
struct PerformanceTaskCatalogView: View {

    /// The three panes the left navigation switches between.
    enum Pane: Hashable {
        case maintenanceTasks
        case loginItems
        case backgroundItems
    }

    /// Which pane is shown. Bound to the owning view so the selection survives
    /// the "Working…" remount and so a dashboard card can open a specific pane.
    @Binding var pane: Pane
    /// Selected maintenance-task ids, bound to the owning view so the selection
    /// persists across the progress screen and a completed run.
    @Binding var selectedTaskIDs: Set<String>
    let tasks: [MaintenanceTask]
    let results: [String: String]
    let loginItems: [LoginItem]
    let userAgents: [LaunchAgent]
    let systemAgents: [LaunchAgent]
    let onRunSelected: ([MaintenanceTask]) -> Void
    /// Removes the current selection: `loginItemIDs` are unregistered and
    /// `agentIDs` (user agents only) have their plists deleted.
    let onRemoveSelected: (_ loginItemIDs: Set<String>, _ agentIDs: Set<String>) -> Void
    let onBack: () -> Void

    /// Checkbox selection for the Login Items and Background Items panes. Held
    /// here (not on the owning view) because it is a within-manager concern that
    /// is consumed the moment Remove runs and the panes reload.
    @State private var selectedLoginIDs: Set<String> = []
    @State private var selectedAgentIDs: Set<String> = []
    @State private var search = ""
    // The manager's items carry no byte size, so Name is the meaningful default.
    @State private var sort: ManagerSort = .name
    @State private var confirmRemove = false

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
            Button(action: onBack) {
                // HStack(Image, Text) rather than Label so the control surfaces
                // reliably in XCUITest.
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
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
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "Search", comment: "Placeholder in the Performance Manager search field."),
                    text: $search
                )
                .textFieldStyle(.plain)
                .frame(width: 140)
                .accessibilityIdentifier("performance.manager.search")
            }

            Menu {
                ForEach(ManagerSort.allCases) { option in
                    Button(option.label) { sort = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "Sort by:", comment: "Label preceding the sort option on the Performance Manager."))
                        .foregroundStyle(.secondary)
                    Text(sort.label).foregroundStyle(.tint)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("performance.manager.sort")
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
                selection: $selectedLoginIDs,
                footnote: nil
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
                footnote: systemAgents.isEmpty ? nil : String.localizedStringWithFormat(
                    String(
                        localized: "%lld more items are managed by macOS and can be changed only in System Settings.",
                        comment: "Note under the Background Items list explaining the macOS-managed daemons aren't removable here."
                    ),
                    systemAgents.count
                )
            )
        }
    }

    /// A checkbox list pane (Login Items / Background Items): a header, a
    /// `Select:` menu, the `ManagerItemTable`, and an optional footnote.
    @ViewBuilder
    private func itemListPane(
        paneKey: String,
        title: String,
        description: String,
        items: [ManagerItem],
        selection: Binding<Set<String>>,
        footnote: String?
    ) -> some View {
        let allIDs = items.map(\.id)
        let displayed = filteredSorted(items)
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(title: title, description: description)
            selectRow(paneKey: paneKey, allIDs: allIDs, selection: selection)
            if displayed.isEmpty {
                Spacer()
                Text(String(localized: "Nothing to review", comment: "Empty state in a Performance Manager pane."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ManagerItemTable(
                    items: displayed,
                    showsSelection: true,
                    isSelected: { selection.wrappedValue.contains($0) },
                    onToggle: { toggle($0, in: selection) },
                    accent: ManagerChrome.accent,
                    rowHeight: 44,
                    contentToken: "\(paneKey)|\(displayed.count)|\(displayed.first?.id ?? "")|\(sort.rawValue)|\(search)",
                    accessibilityPrefix: "performance.manager.\(paneKey)",
                    forcesLightAppearance: true,
                    showsSparkle: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The title + one-line description atop a pane, mirroring the Cleanup
    /// Manager's pane header.
    private func paneHeader(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The `Select:` bulk-select menu, scoped to the pane's items.
    private func selectRow(paneKey: String, allIDs: [String], selection: Binding<Set<String>>) -> some View {
        let selectedCount = allIDs.reduce(0) { $0 + (selection.wrappedValue.contains($1) ? 1 : 0) }
        return HStack(spacing: 8) {
            Text(String(localized: "Select:", comment: "Label before the bulk-select menu on the Performance Manager."))
                .foregroundStyle(.secondary)
            Menu {
                Button(String(localized: "Smartly", comment: "Bulk-select the recommended items.")) {
                    selection.wrappedValue.formUnion(allIDs)
                }
                Button(String(localized: "Select All", comment: "Bulk-select every item in the pane.")) {
                    selection.wrappedValue.formUnion(allIDs)
                }
                .disabled(selectedCount == allIDs.count || allIDs.isEmpty)
                Button(String(localized: "Deselect All", comment: "Bulk-deselect every item in the pane.")) {
                    allIDs.forEach { selection.wrappedValue.remove($0) }
                }
                .disabled(selectedCount == 0)
            } label: {
                Text(bulkSelectLabel(selected: selectedCount, total: allIDs.count))
                    .foregroundStyle(.tint)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("performance.manager.\(paneKey).select")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 8)
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

                VStack(spacing: 10) {
                    ForEach(displayedTasks) { task in
                        PerformanceTaskRow(
                            task: task,
                            tint: PerformanceTaskPalette.tint(for: task.kind),
                            isSelected: selectedTaskIDs.contains(task.id),
                            result: results[task.id],
                            onToggle: { toggleTask(task) }
                        )
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
                onRunSelected(tasks.filter { selectedTaskIDs.contains($0.id) })
            }
            .buttonStyle(.vaderProminent)
            .disabled(selectedTaskIDs.isEmpty)
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

    private var loginManagerItems: [ManagerItem] {
        loginItems.map { item in
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
    }

    private var agentManagerItems: [ManagerItem] {
        userAgents.map { agent in
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
    }

    private func loginSubtitle(_ item: LoginItem) -> String {
        if item.requiresApproval {
            return String(
                localized: "Pending — approve in System Settings",
                comment: "Login-item subtitle when the registration awaits the user's approval."
            )
        }
        return item.isEnabled
            ? String(localized: "Enabled", comment: "Login-item subtitle when it opens at login.")
            : String(localized: "Disabled", comment: "Login-item subtitle when it does not open at login.")
    }

    /// The icon source for an agent row: its program's app bundle when the
    /// program lives inside one (so updaters show the parent app's icon), else
    /// the plist itself (a generic .plist document icon, as in the reference).
    private func agentIconPath(_ agent: LaunchAgent) -> String {
        if let program = agent.programPath, let range = program.range(of: ".app") {
            return String(program[..<range.upperBound])
        }
        return agent.path.path
    }

    // MARK: - Derived data

    private func filteredSorted(_ items: [ManagerItem]) -> [ManagerItem] {
        let filtered = search.isEmpty
            ? items
            : items.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .name:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .size:
            // These items carry no byte size, so keep their natural load order.
            return filtered
        }
    }

    private var displayedTasks: [MaintenanceTask] {
        let filtered = search.isEmpty
            ? tasks
            : tasks.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .name:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .size:
            return filtered
        }
    }

    private var currentPaneSelectedCount: Int {
        switch pane {
        case .loginItems:      return selectedLoginIDs.count
        case .backgroundItems: return selectedAgentIDs.count
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
    /// removes exactly what it shows.
    private func performRemove() {
        switch pane {
        case .loginItems:
            onRemoveSelected(selectedLoginIDs, [])
            selectedLoginIDs.removeAll()
        case .backgroundItems:
            onRemoveSelected([], selectedAgentIDs)
            selectedAgentIDs.removeAll()
        case .maintenanceTasks:
            break
        }
    }

    // MARK: - Footer text

    private var tasksSelectedSummary: String {
        String.localizedStringWithFormat(
            String(localized: "%lld Tasks Selected", comment: "Footer count of selected maintenance tasks."),
            selectedTaskIDs.count
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

    private var removeConfirmationMessage: String {
        let count = currentPaneSelectedCount
        switch pane {
        case .loginItems:
            return String.localizedStringWithFormat(
                String(
                    localized: "%lld login item(s) will stop opening at login.",
                    comment: "Performance Manager remove confirmation for login items."
                ),
                count
            )
        case .backgroundItems:
            return String.localizedStringWithFormat(
                String(
                    localized: "%lld background item(s) will be permanently removed from disk. This cannot be undone.",
                    comment: "Performance Manager remove confirmation for background items."
                ),
                count
            )
        case .maintenanceTasks:
            return ""
        }
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

/// One selectable maintenance task — a checkbox, a colourful icon badge, the
/// task name, an info button explaining what it does, and (after running) the
/// most recent result line.
struct PerformanceTaskRow: View {
    let task: MaintenanceTask
    let tint: Color
    let isSelected: Bool
    let result: String?
    let onToggle: () -> Void

    private var isCompleted: Bool { result != nil }

    /// Always-present secondary line: the task summary normally, the result once
    /// it has run. Kept to one line so the row height never changes.
    private var subtitle: String { result ?? task.summary }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityIdentifier("performance.task.checkbox.\(task.kind.rawValue)")

            TaskIconBadge(symbol: task.icon, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                    // Clear success indicator once the task has run.
                    if isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityIdentifier("performance.task.done.\(task.kind.rawValue)")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isCompleted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The full result/summary is available on hover; the row
                    // stays one line so its height is stable.
                    .help(subtitle)
            }

            Spacer()

            // Decorative "smart suggestion" sparkle, matching the pink sparkle on
            // the Login Items / Background Items rows so every pane shares one
            // trailing column.
            Image(systemName: "sparkles")
                .font(.system(size: 15))
                .foregroundStyle(.pink)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("performance.task.\(task.kind.rawValue)")
        .animation(.smooth(duration: 0.25), value: isCompleted)
    }
}

/// A colourful rounded-square icon badge — the SF Symbol on a per-task tinted
/// gradient, giving each task a distinct, app-like glyph.
struct TaskIconBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        let fill = tint.deepenedForWhite
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(
                LinearGradient(
                    colors: [fill.opacity(0.95), fill.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: .rect(cornerRadius: 10)
            )
    }
}

/// Per-task accent colours for the icon badges. Kept in the view layer so the
/// `MaintenanceTask` model stays free of UI types.
enum PerformanceTaskPalette {
    static func tint(for kind: MaintenanceTask.Kind) -> Color {
        switch kind {
        case .freeUpRAM:
            return Color(red: 0.95, green: 0.45, blue: 0.20)
        case .runMaintenanceScripts:
            return Color(red: 0.55, green: 0.45, blue: 0.95)
        case .flushDNS:
            return Color(red: 0.96, green: 0.62, blue: 0.24)
        case .reindexSpotlight:
            return Color(red: 0.95, green: 0.76, blue: 0.20)
        case .thinTimeMachineSnapshots:
            return Color(red: 0.96, green: 0.55, blue: 0.30)
        case .speedUpMail:
            return Color(red: 0.36, green: 0.62, blue: 0.96)
        }
    }
}
