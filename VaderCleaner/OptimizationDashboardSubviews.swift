// OptimizationDashboardSubviews.swift
// Curated-recommendations dashboard and the "View All Tasks" catalog for the Optimization screen — glass recommendation cards, the maintenance-task list, and the folded-in background-items (login items / launch agents) sections.

import SwiftUI

// MARK: - Dashboard

/// The Optimization landing surface: a header tagline, a "View All Tasks"
/// affordance, and the curated recommendation cards (a tall hero card on the
/// left, the rest in an adaptive grid), mirroring the Performance dashboard.
struct OptimizationDashboardView: View {
    let recommendations: [PerformanceRecommendation]
    /// Recommendation kinds whose action has completed — their tiles show a check.
    let completedKinds: Set<PerformanceRecommendation.Kind>
    let onAction: (PerformanceRecommendation) -> Void
    let onViewAllTasks: () -> Void

    private var hero: PerformanceRecommendation? {
        recommendations.first { $0.isHero }
    }

    private var standardCards: [PerformanceRecommendation] {
        recommendations.filter { !$0.isHero }
    }

    var body: some View {
        VStack(spacing: 28) {
            header
            if recommendations.isEmpty {
                emptyState
            } else {
                cardLayout
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("optimization.dashboard")
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text(String(
                localized: "Apply curated recommendations\nor run performance tasks manually.",
                comment: "Optimization dashboard tagline."
            ))
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

            Button(action: onViewAllTasks) {
                Text(String(
                    localized: "View All Tasks",
                    comment: "Button that opens the full maintenance-task catalog."
                ))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("optimization.viewAllTasks")
        }
    }

    private var cardLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            if let hero {
                PerformanceRecommendationCard(
                    recommendation: hero,
                    isCompleted: completedKinds.contains(hero.kind)
                ) { onAction(hero) }
                    .frame(maxWidth: 320)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(standardCards) { recommendation in
                    PerformanceRecommendationCard(
                        recommendation: recommendation,
                        isCompleted: completedKinds.contains(recommendation.kind)
                    ) {
                        onAction(recommendation)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(String(
                localized: "Your Mac is in good shape",
                comment: "Optimization dashboard empty-state title."
            ))
            .font(.title3.weight(.semibold))
            Text(String(
                localized: "No performance recommendations right now. You can still run any task manually.",
                comment: "Optimization dashboard empty-state detail."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .accessibilityIdentifier("optimization.dashboard.empty")
    }
}

/// A single curated recommendation card. Uses the same glass surface and corner
/// radius as the Smart Scan / Health dashboards so the app's card surfaces stay
/// consistent. The hero card is rendered taller. When its action has completed,
/// a green check replaces the icon and the button reads "Done".
struct PerformanceRecommendationCard: View {
    let recommendation: PerformanceRecommendation
    var isCompleted: Bool = false
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(recommendation.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: isCompleted ? "checkmark.circle.fill" : recommendation.icon)
                    .font(.title2)
                    .foregroundStyle(isCompleted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityIdentifier(
                        isCompleted ? "optimization.recommendation.\(recommendation.kind.rawValue).done" : ""
                    )
            }
            Text(recommendation.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack {
                Spacer()
                Button(action: onAction) {
                    if isCompleted {
                        Label(
                            String(localized: "Done", comment: "Recommendation card button after its action completed."),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(recommendation.actionLabel)
                    }
                }
                .buttonStyle(.vaderProminent)
                .tint(isCompleted ? .green : nil)
                .accessibilityIdentifier("optimization.recommendation.\(recommendation.kind.rawValue)")
            }
        }
        .padding(18)
        .frame(
            maxWidth: .infinity,
            minHeight: recommendation.isHero ? 260 : 150,
            alignment: .leading
        )
        // 12 matches the Smart Scan / Health cards so every dashboard card
        // surface shares one corner radius.
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .animation(.smooth(duration: 0.25), value: isCompleted)
    }
}

// MARK: - Task catalog

/// The "View All Tasks" surface, modelled on a Performance Manager: a back
/// affordance, a left sub-navigation (Maintenance Tasks / Login Items /
/// Background Items), and a detail pane. The Maintenance Tasks pane is a
/// multi-select checklist with a "Run" bar that runs every selected task at
/// once; the other two panes host the existing management sections.
struct OptimizationTaskCatalogView: View {

    /// The three catalog panes the sub-navigation switches between.
    enum Pane: Hashable {
        case maintenanceTasks
        case loginItems
        case backgroundItems
    }

    /// Which pane is shown. Bound to the owning view so the selection survives
    /// the "Working…" remount and so a dashboard card can open a specific pane.
    @Binding var pane: Pane
    /// Selected task ids, bound to the owning view so the selection persists
    /// across the progress screen and a completed run.
    @Binding var selectedTaskIDs: Set<String>
    let tasks: [MaintenanceTask]
    let results: [String: String]
    let loginItems: [LoginItem]
    let userAgents: [LaunchAgent]
    let systemAgents: [LaunchAgent]
    let onRunSelected: ([MaintenanceTask]) -> Void
    let onToggleLoginItem: (LoginItem, Bool) -> Void
    let onApproveLoginItem: () -> Void
    let onSetAgentEnabled: (LaunchAgent, Bool) -> Void
    let onRemoveAgent: (LaunchAgent) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                subNavigation
                    .frame(width: 220)
                    .padding(16)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("optimization.catalog")
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: onBack) {
                // HStack(Image, Text) rather than Label so the control surfaces
                // reliably in XCUITest.
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(String(
                        localized: "Back",
                        comment: "Back button returning from the task catalog to the dashboard."
                    ))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("optimization.backToDashboard")
            Spacer()
            Text(String(
                localized: "Performance Manager",
                comment: "Title of the View All Tasks catalog."
            ))
            .font(.headline)
            Spacer()
            // Balances the leading Back button so the title stays centred.
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(16)
    }

    // MARK: Sub-navigation

    private var subNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            navItem(.maintenanceTasks,
                    String(localized: "Maintenance Tasks", comment: "Catalog sub-nav item."),
                    "optimization.catalog.nav.maintenanceTasks")
            navItem(.loginItems,
                    String(localized: "Login Items", comment: "Catalog sub-nav item."),
                    "optimization.catalog.nav.loginItems")
            navItem(.backgroundItems,
                    String(localized: "Background Items", comment: "Catalog sub-nav item."),
                    "optimization.catalog.nav.backgroundItems")
            Spacer()
        }
    }

    private func navItem(_ target: Pane, _ title: String, _ identifier: String) -> some View {
        Button {
            pane = target
        } label: {
            Text(title)
                .font(.body.weight(pane == target ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    pane == target ? Color.primary.opacity(0.10) : .clear,
                    in: .rect(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        switch pane {
        case .maintenanceTasks:
            maintenanceTasksPane
        case .loginItems:
            paneScroll {
                OptimizationLoginItemsSection(
                    items: loginItems,
                    onToggle: onToggleLoginItem,
                    onApprove: onApproveLoginItem
                )
            }
        case .backgroundItems:
            paneScroll {
                OptimizationLaunchAgentsSection(
                    title: String(
                        localized: "Launch Agents (User)",
                        comment: "Section header for user launch agents."
                    ),
                    identifier: "optimization.userAgents",
                    agents: userAgents,
                    onSetEnabled: onSetAgentEnabled,
                    onRemove: onRemoveAgent
                )
                OptimizationLaunchAgentsSection(
                    title: String(
                        localized: "Launch Agents & Daemons (System)",
                        comment: "Section header for system launch agents and daemons."
                    ),
                    subtitle: String(
                        localized: "Managed by macOS · change these in System Settings or the app that installed them",
                        comment: "Note under the system launch-agents header explaining the whole group is read-only here."
                    ),
                    identifier: "optimization.systemAgents",
                    agents: systemAgents,
                    onSetEnabled: onSetAgentEnabled,
                    onRemove: onRemoveAgent
                )
            }
        }
    }

    private func paneScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var maintenanceTasksPane: some View {
        VStack(spacing: 0) {
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
                        ForEach(tasks) { task in
                            OptimizationTaskRow(
                                task: task,
                                tint: OptimizationTaskPalette.tint(for: task.kind),
                                isSelected: selectedTaskIDs.contains(task.id),
                                result: results[task.id],
                                onToggle: { toggle(task) }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            runBar
        }
    }

    private var runBar: some View {
        ZStack {
            Text(selectionSummary)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
                Spacer()
                Button(String(localized: "Run", comment: "Runs the selected maintenance tasks.")) {
                    onRunSelected(tasks.filter { selectedTaskIDs.contains($0.id) })
                }
                .buttonStyle(.vaderProminent)
                .disabled(selectedTaskIDs.isEmpty)
                .accessibilityIdentifier("optimization.runSelected")
            }
        }
        .padding(16)
    }

    private var selectionSummary: String {
        let format = String(
            localized: "%d Tasks Selected",
            comment: "Footer count of selected maintenance tasks; %d is the count."
        )
        return String.localizedStringWithFormat(format, selectedTaskIDs.count)
    }

    private func toggle(_ task: MaintenanceTask) {
        if selectedTaskIDs.contains(task.id) {
            selectedTaskIDs.remove(task.id)
        } else {
            selectedTaskIDs.insert(task.id)
        }
    }
}

/// One selectable maintenance task — a checkbox, a colourful icon badge, the
/// task name, an info button explaining what it does, and (after running) the
/// most recent result line.
struct OptimizationTaskRow: View {
    let task: MaintenanceTask
    let tint: Color
    let isSelected: Bool
    let result: String?
    let onToggle: () -> Void

    @State private var showInfo = false

    private var isCompleted: Bool { result != nil }

    /// Always-present secondary line: the task summary normally, the result once
    /// it has run. Kept to one line so the row height never changes.
    private var subtitle: String { result ?? task.summary }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityIdentifier("optimization.task.checkbox.\(task.kind.rawValue)")

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
                            .accessibilityIdentifier("optimization.task.done.\(task.kind.rawValue)")
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

            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("optimization.task.info.\(task.kind.rawValue)")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                TaskInfoPopover(task: task, tint: tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("optimization.task.\(task.kind.rawValue)")
        .animation(.smooth(duration: 0.25), value: isCompleted)
    }
}

/// A colourful rounded-square icon badge — the SF Symbol on a per-task tinted
/// gradient, giving each task a distinct, app-like glyph.
struct TaskIconBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint.legibleForeground)
            .frame(width: 38, height: 38)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: .rect(cornerRadius: 10)
            )
    }
}

/// The popover shown by a task row's info button — what the task does, in the
/// task's own words.
struct TaskInfoPopover: View {
    let task: MaintenanceTask
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TaskIconBadge(symbol: task.icon, tint: tint)
                Text(task.title).font(.headline)
            }
            Text(task.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Per-task accent colours for the icon badges. Kept in the view layer so the
/// `MaintenanceTask` model stays free of UI types.
enum OptimizationTaskPalette {
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
