// SmartInsights.swift
// On-device Apple Intelligence summaries for Cleanup Manager rows — what an item is and whether it's safe to delete — shown in the row's Smart Insights popover.

import SwiftUI
import FoundationModels

// MARK: - Model

/// A structured Smart Insight the on-device model generates for a file or folder.
@Generable
struct SmartInsight {
    @Guide(description: "One or two plain-language sentences explaining what this file or folder is and whether it is generally safe to delete during a storage cleanup.")
    let summary: String
    @Guide(description: "The one category that best fits the item, for a non-technical person: app for an application; system for part of macOS that should be handled with care; media for photos, videos, or music; documents for documents and personal files; temporaryFiles for caches and temporary junk that is safe to clear; browser for a web browser or its stored data; developer for coding and development tools; games for games; other for anything that fits none of these.")
    let category: SmartInsightCategory
}

/// A fixed set of plain-language categories the model classifies an item into,
/// each with its own pill color. Constrained rather than free text so the tag is
/// predictable and a non-technical person can read it at a glance.
@Generable
enum SmartInsightCategory {
    case app
    case system
    case media
    case documents
    case temporaryFiles
    case browser
    case developer
    case games
    case other

    /// The short text shown on the pill.
    var label: String {
        switch self {
        case .app: return String(localized: "App")
        case .system: return String(localized: "System")
        case .media: return String(localized: "Media")
        case .documents: return String(localized: "Documents")
        case .temporaryFiles: return String(localized: "Temporary")
        case .browser: return String(localized: "Browser")
        case .developer: return String(localized: "Developer")
        case .games: return String(localized: "Games")
        case .other: return String(localized: "Other")
        }
    }

    /// The pill's accent color — its text, over a soft fill of the same color.
    var color: Color {
        switch self {
        case .app: return .blue
        case .system: return .gray
        case .media: return .pink
        case .documents: return .teal
        case .temporaryFiles: return .green
        case .browser: return .indigo
        case .developer: return .purple
        case .games: return .orange
        case .other: return .brown
        }
    }
}

extension SmartInsightCategory: CaseIterable {}

/// What kind of thing a Smart Insight is about, so the popover speaks to it
/// correctly across managers — a cache folder, an app, a maintenance task, a
/// login item, or browser data. Each case carries the instructions, prompt, and
/// loading-line noun that suit it. Kept pure so the wording is unit-testable
/// without invoking the on-device model.
enum SmartInsightsTopic {
    case fileOrFolder
    case application
    case appExtension
    case maintenanceTask
    case loginItem
    case privacyData
    /// A Smart Scan care-plan finding (a whole category of results, e.g.
    /// "Duplicate files"), explained with an emphasis on whether acting on
    /// it is safe.
    case careFinding

    /// The noun used in the loading line ("Giving this <noun> some thought…").
    var loadingNoun: String {
        switch self {
        case .fileOrFolder: return String(localized: "file")
        case .application: return String(localized: "app")
        case .appExtension: return String(localized: "extension")
        case .maintenanceTask: return String(localized: "task")
        case .loginItem: return String(localized: "item")
        case .privacyData: return String(localized: "data")
        case .careFinding: return String(localized: "finding")
        }
    }

    /// System instructions orienting the model for this kind of item.
    var instructions: String {
        switch self {
        case .fileOrFolder:
            return """
                You explain what a file or folder on a Mac is, in plain language, to \
                help someone decide whether it is safe to delete during a storage \
                cleanup. Be concise and factual. If you are not certain what the \
                item is, say so rather than guessing.
                """
        case .application:
            return """
                You explain what a macOS app is and what it is typically used for, in \
                plain language, to help someone decide whether they still need it or \
                can uninstall it. Be concise and factual. If you are not certain what \
                the app is, say so rather than guessing.
                """
        case .appExtension:
            return """
                You explain what a browser or app extension is and what it does, in \
                plain language, to help someone decide whether to keep or remove it. \
                Be concise and factual. If you are not certain what the extension is, \
                say so rather than guessing.
                """
        case .maintenanceTask:
            return """
                You explain what a macOS maintenance task does and what running it \
                accomplishes, in plain language, to help someone decide whether to \
                run it. Be concise and factual. If you are not certain what the task \
                is, say so rather than guessing.
                """
        case .loginItem:
            return """
                You explain what a macOS login or background item is and what it does, \
                in plain language, to help someone decide whether to disable it. Be \
                concise and factual. If you are not certain what the item is, say so \
                rather than guessing.
                """
        case .privacyData:
            return """
                You explain what a category of stored browser or app data is — such as \
                cookies, cache, or history — and whether it is generally safe to \
                remove, in plain language. Be concise and factual. If you are not \
                certain what the data is, say so rather than guessing.
                """
        case .careFinding:
            return """
                You explain a category of Mac-cleanup findings — such as duplicate \
                files, old caches, or unused apps — to someone who is not technical: \
                what it is, why it accumulates, and whether cleaning it is safe. Be \
                concise and factual. If you are not certain, say so rather than \
                guessing.
                """
        }
    }

    /// The user prompt asking about one specific named item.
    func prompt(for itemName: String) -> String {
        switch self {
        case .fileOrFolder:
            return "Explain what this item on the user's Mac is and whether it is generally safe to delete during a cleanup. Item name: \"\(itemName)\"."
        case .application:
            return "Explain what this Mac app is and what it is typically used for. App name: \"\(itemName)\"."
        case .appExtension:
            return "Explain what this browser or app extension is and what it does. Extension name: \"\(itemName)\"."
        case .maintenanceTask:
            return "Explain what this Mac maintenance task does when it runs. Task name: \"\(itemName)\"."
        case .loginItem:
            return "Explain what this Mac login or background item is and what it does. Item name: \"\(itemName)\"."
        case .privacyData:
            return "Explain what this stored browser or app data is and whether it is generally safe to remove. Item: \"\(itemName)\"."
        case .careFinding:
            return "Explain this kind of Mac-cleanup finding and whether cleaning it up is safe. Finding: \"\(itemName)\"."
        }
    }
}

// MARK: - View model

/// Drives one Smart Insights popover: checks model availability, generates the
/// insight on-device, and exposes the state the popover renders.
@MainActor
@Observable
final class SmartInsightsViewModel {
    enum State {
        case loading
        case result(SmartInsight)
        /// The model can't run; the string explains why (Apple Intelligence off,
        /// device ineligible, still downloading, …).
        case unavailable(String)
        case failed
    }

    private(set) var state: State = .loading
    private let itemName: String
    private let topic: SmartInsightsTopic

    init(itemName: String, topic: SmartInsightsTopic) {
        self.itemName = itemName
        self.topic = topic
    }

    /// Generates the insight for the item, updating `state` as it goes. Safe to
    /// abandon: the enclosing SwiftUI `.task` cancels this when the popover closes.
    func generate() async {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            state = .unavailable(Self.message(for: availability))
            return
        }
        do {
            let session = LanguageModelSession(instructions: topic.instructions)
            let response = try await session.respond(
                to: topic.prompt(for: itemName),
                generating: SmartInsight.self
            )
            state = .result(response.content)
        } catch {
            state = .failed
        }
    }

    /// Maps an unavailable status to a short line the popover can show.
    private static func message(for availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return ""
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Turn on Apple Intelligence in System Settings to use Smart Insights.")
        case .unavailable(.deviceNotEligible):
            return String(localized: "Smart Insights isn't available on this Mac.")
        case .unavailable(.modelNotReady):
            return String(localized: "The on-device model is still getting ready. Try again in a moment.")
        case .unavailable:
            return String(localized: "Smart Insights is unavailable right now.")
        }
    }
}

// MARK: - Popover UI

/// The Smart Insights popover shown when a row's sparkle is clicked. Opens in a
/// "thinking" loading state, then shows the generated summary, a category tag,
/// feedback controls, and the Apple Intelligence footer.
struct SmartInsightsPopoverView: View {
    @State private var model: SmartInsightsViewModel
    private let loadingNoun: String

    init(itemTitle: String, topic: SmartInsightsTopic = .fileOrFolder) {
        _model = State(initialValue: SmartInsightsViewModel(itemName: itemTitle, topic: topic))
        loadingNoun = topic.loadingNoun
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // The dark bubble from the design, kept readable in every manager by
        // pinning its own dark surface and color scheme rather than relying on
        // the host popover's appearance.
        .background(Color(red: 0.17, green: 0.16, blue: 0.19))
        .environment(\.colorScheme, .dark)
        .task { await model.generate() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.45, blue: 0.85),
                            Color(red: 0.62, green: 0.40, blue: 0.98),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("Smart Insights", comment: "Header of the Smart Insights popover.")
                .font(.system(size: 14, weight: .semibold))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            Text(String(format: String(localized: "Giving this %@ some thought…", comment: "Loading line while Smart Insights generates; %@ is a noun like file, app, or task."), loadingNoun))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .shimmering()
        case .result(let insight):
            resultView(insight)
        case .unavailable(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed:
            Text("Couldn't generate insights. Please try again.", comment: "Smart Insights error line.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func resultView(_ insight: SmartInsight) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(insight.summary)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Text(insight.category.label)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(insight.category.color.opacity(0.22), in: Capsule())
                .foregroundStyle(insight.category.color)
            Divider().opacity(0.3)
            SmartInsightsFeedbackControls()
            Divider().opacity(0.3)
            Text("Powered by Apple Intelligence", comment: "Smart Insights footer.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// The clickable Smart Insights sparkle for a SwiftUI manager row — the peer of
/// the AppKit `ManagerSparkleView`. Shows a squircle hover chip in the manager's
/// accent, a tooltip, and opens the Smart Insights popover for its item.
struct SmartInsightsSparkle: View {
    let itemTitle: String
    var accent: Color = ManagerChrome.accent
    var topic: SmartInsightsTopic = .fileOrFolder

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 15))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(isHovering ? 0.18 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text("Get smart insights about this item", comment: "Tooltip on a manager row's smart-insights sparkle."))
        .accessibilityLabel(Text("Smart Insights", comment: "Accessibility label for a manager row's smart-insights sparkle button."))
        .popover(isPresented: $isPresented) {
            SmartInsightsPopoverView(itemTitle: itemTitle, topic: topic)
        }
    }
}

/// The thumbs down / up controls under a generated insight. The vote is local to
/// the popover for now — a lightweight affordance, not yet reported anywhere.
private struct SmartInsightsFeedbackControls: View {
    private enum Vote { case up, down }
    @State private var vote: Vote?

    var body: some View {
        HStack(spacing: 18) {
            Spacer()
            voteButton(.down, symbol: "hand.thumbsdown")
            voteButton(.up, symbol: "hand.thumbsup")
        }
    }

    private func voteButton(_ value: Vote, symbol: String) -> some View {
        Button {
            vote = (vote == value) ? nil : value
        } label: {
            Image(systemName: vote == value ? "\(symbol).fill" : symbol)
                .font(.system(size: 13))
                .foregroundStyle(vote == value ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Loading shimmer

/// A left-to-right highlight sweep over the content — the "thinking" shimmer
/// shown while Smart Insights generates, mirroring the loading state in AI chats.
private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.85), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 0.5)
                    // Sweep the highlight band from just off the left edge to just
                    // off the right edge, then loop.
                    .offset(x: -width * 0.6 + phase * width * 1.7)
                    .blendMode(.screen)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    /// Applies the Smart Insights "thinking" shimmer.
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}
