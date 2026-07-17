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
    @Guide(description: "A single short category label such as Developer, Browser, System, Media, Cache, or Document.")
    let category: String
}

/// The instructions and prompt used to generate a `SmartInsight`. Kept pure and
/// separate from the model call so the wording is unit-testable without invoking
/// the on-device model.
enum SmartInsightsPrompt {
    static let instructions = """
        You explain what a file or folder on a Mac is, in plain language, to help \
        someone decide whether it is safe to delete during a storage cleanup. Be \
        concise and factual. If you are not certain what the item is, say so \
        rather than guessing.
        """

    static func text(for itemName: String) -> String {
        """
        Explain what this item on the user's Mac is and whether it is generally \
        safe to delete during a cleanup. Item name: "\(itemName)".
        """
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

    init(itemName: String) {
        self.itemName = itemName
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
            let session = LanguageModelSession(instructions: SmartInsightsPrompt.instructions)
            let response = try await session.respond(
                to: SmartInsightsPrompt.text(for: itemName),
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

    init(itemTitle: String) {
        _model = State(initialValue: SmartInsightsViewModel(itemName: itemTitle))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
            Text("Giving this file some thought…", comment: "Loading line while Smart Insights generates.")
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
            if !insight.category.isEmpty {
                Text(insight.category)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.22), in: Capsule())
                    .foregroundStyle(Color.green)
            }
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
