// CarePlanFeedView.swift
// The results experience: a plain-language health verdict hero over a prioritized feed of care cards, each saying what was found, why it matters, and whether acting is safe.

import SwiftUI

/// The care-plan feed shown when a scan lands. Threats lead, space findings
/// follow by size, advisory notes close the feed; every card carries a
/// safety pill so a non-technical user always knows whether acting can lose
/// anything. The floating Run disc (hosted in a separate panel) is the one
/// "fix it" action; cards only toggle inclusion or open Review.
struct CarePlanFeedView: View {

    var viewModel: SmartScanViewModel
    /// Kinds whose Review screen exists; cards for other kinds hide the
    /// Review affordance rather than dead-ending.
    let reviewableKinds: Set<CareFinding.Kind>
    let onRequestReview: (CareFinding.Kind) -> Void
    let onStartOver: () -> Void
    @Environment(\.sectionAccent) private var accent
    /// Optional so previews and tests need not inject a store.
    @Environment(CareHistoryStore.self) private var history: CareHistoryStore?

    var body: some View {
        ScrollView {
            // One glass container for the hero and every card: independent
            // glass surfaces each pay their own render pass, which made
            // scrolling the feed stutter; merged they resolve together.
            GlassEffectContainer(spacing: 14) {
                feedContent
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.resultsFeed")
    }

    private var feedContent: some View {
            VStack(spacing: 24) {
                topBar
                if let verdict = viewModel.verdict {
                    CareVerdictHero(
                        verdict: verdict,
                        historyLine: history?.lifetimeFreedLine(),
                        coverageNote: coverageNote
                    )
                }
                if viewModel.rankedFindings.isEmpty {
                    ReassuranceCard(
                        content: ReassuranceContent(
                            id: "smartScan.allClear",
                            title: String(localized: "Nothing needs your attention", comment: "All-clear card title on the care-plan feed."),
                            detail: String(
                                localized: "We checked junk, threats, apps, and more — your Mac is in good hands.",
                                comment: "All-clear card detail on the care-plan feed."
                            ),
                            icon: "checkmark.seal.fill"
                        ),
                        accent: accent
                    )
                    .frame(maxWidth: 560)
                } else {
                    VStack(spacing: 14) {
                        ForEach(viewModel.rankedFindings) { finding in
                            CareCardView(
                                finding: finding,
                                isIncluded: viewModel.isFindingIncluded(finding.kind),
                                showsReview: reviewableKinds.contains(finding.kind),
                                onToggleInclusion: { toggleInclusion(of: finding) },
                                onReview: { onRequestReview(finding.kind) }
                            )
                        }
                    }
                    .frame(maxWidth: 640)
                }
                Spacer(minLength: 80)
            }
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
    }

    private var topBar: some View {
        HStack {
            Button(action: onStartOver) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(String(localized: "Start Over", comment: "Button returning from results to the Smart Scan intro."))
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.vaderGlass)
            .accessibilityIdentifier("smartScan.startOver")
            Spacer()
        }
        .frame(maxWidth: 640)
    }

    /// Honest coverage line when parts of the scan were skipped or failed.
    private var coverageNote: String? {
        guard let plan = viewModel.currentPlan else { return nil }
        var notes: [String] = []
        let failedDomains = orderedDomains(of: plan.failedUnits)
        if !failedDomains.isEmpty {
            notes.append(String.localizedStringWithFormat(
                String(localized: "We couldn't check: %@.", comment: "Coverage note listing domains whose scan failed."),
                failedDomains.map(\.title).joined(separator: ", ")
            ))
        }
        let skippedDomains = orderedDomains(of: plan.skippedUnits)
        if !skippedDomains.isEmpty {
            notes.append(String.localizedStringWithFormat(
                String(localized: "Not included in your scan settings: %@.", comment: "Coverage note listing domains excluded from the scan."),
                skippedDomains.map(\.title).joined(separator: ", ")
            ))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// A domain appears only when *every* one of its units is in the given
    /// list — a domain that landed partial results still shows its findings,
    /// and naming it here would contradict them.
    private func orderedDomains(of units: [CareScanUnit]) -> [CareDomain] {
        let unitSet = Set(units)
        return CareDomain.allCases.filter { domain in
            !domain.units.isEmpty && domain.units.allSatisfy(unitSet.contains)
        }
    }

    /// Turning an opt-in card on with nothing selected silently selecting
    /// everything would betray the safety pill — deep-link into Review so
    /// the user picks what goes.
    private func toggleInclusion(of finding: CareFinding) {
        let isIncluded = viewModel.isFindingIncluded(finding.kind)
        if !isIncluded,
           finding.actionability == .optIn,
           viewModel.selectionCount(for: finding.kind) == 0 {
            onRequestReview(finding.kind)
            return
        }
        viewModel.setFindingIncluded(finding.kind, !isIncluded)
    }
}

/// The verdict hero: a tiered ring, a headline in everyday words, and the
/// one-line summary of what is worth doing.
private struct CareVerdictHero: View {

    let verdict: CareVerdict
    let historyLine: String?
    let coverageNote: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 24) {
                ring
                VStack(alignment: .leading, spacing: 6) {
                    Text(verdict.headline)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("smartScan.verdictHeading")
                    Text(verdict.detail)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityIdentifier("smartScan.verdictDetail")
                    if let historyLine {
                        Text(historyLine)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .accessibilityIdentifier("smartScan.historyLine")
                    }
                }
                Spacer(minLength: 0)
            }
            if let coverageNote {
                Text(coverageNote)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("smartScan.coverageNote")
            }
        }
        .padding(24)
        .frame(maxWidth: 640)
        .vaderTileGlass()
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: verdict.status.score)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verdict.status.title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(ringColor)
                .multilineTextAlignment(.center)
                .padding(10)
        }
        .frame(width: 92, height: 92)
        .accessibilityHidden(true)
    }

    private var ringColor: Color {
        switch verdict.status {
        case .critical: return .red
        case .requiresAttention: return .orange
        case .fair: return .yellow
        case .good: return .green
        case .excellent: return .mint
        }
    }
}

/// One finding's card: icon, plain-language copy, safety pill, metric, an
/// inclusion checkbox for actionable findings, and Review.
struct CareCardView: View {

    let finding: CareFinding
    let isIncluded: Bool
    let showsReview: Bool
    let onToggleInclusion: () -> Void
    let onReview: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            icon
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(CareFindingCopy.title(for: finding.kind))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    // On-device Apple Intelligence explanation, availability-
                    // gated inside the sparkle. Pure augmentation: the card's
                    // own copy is always the rendered text.
                    SmartInsightsSparkle(
                        itemTitle: CareFindingCopy.title(for: finding.kind),
                        accent: accent,
                        topic: .careFinding
                    )
                    Spacer(minLength: 8)
                    Text(CareFindingCopy.metric(for: finding))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                Text(CareFindingCopy.explanation(for: finding.kind))
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    safetyPill
                    Spacer(minLength: 0)
                    if showsReview {
                        Button(action: onReview) {
                            Text(reviewTitle)
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(.vaderGlass)
                        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).review")
                    }
                }
                .padding(.top, 4)
            }
            if finding.actionability != .informational {
                inclusionCheckbox
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vaderTileGlass()
        .overlay(alignment: .leading) {
            if finding.urgency == .critical {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.red)
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .padding(.leading, 5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue)")
    }

    private var reviewTitle: String {
        finding.actionability == .optIn
            ? String(localized: "Choose What Goes", comment: "Review button title on opt-in care cards.")
            : String(localized: "Review", comment: "Review button title on care cards.")
    }

    private var icon: some View {
        Image(systemName: iconName)
            .font(.system(size: 20, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(finding.urgency == .critical ? Color.red : Color.white.opacity(0.9))
            .frame(width: 40, height: 40)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    private var iconName: String {
        switch finding.kind {
        case .threats: return "exclamationmark.shield.fill"
        case .lowDiskSpace: return "externaldrive.fill.badge.exclamationmark"
        case .junkCleanup: return "sparkles"
        case .duplicates: return "doc.on.doc.fill"
        case .largeOldFiles: return "shippingbox.fill"
        case .unusedApps: return "square.grid.3x3.slash"
        case .appLeftovers: return "puzzlepiece.extension.fill"
        case .installers: return "arrow.down.circle.fill"
        case .appUpdates: return "arrow.triangle.2.circlepath"
        case .maintenanceDue: return "wrench.and.screwdriver.fill"
        case .browserPrivacy: return "hand.raised.fill"
        case .loginItems: return "power"
        }
    }

    private var safetyPill: some View {
        Text(CareFindingCopy.safetyLine(for: finding.actionability))
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(pillColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(pillColor.opacity(0.14), in: Capsule())
    }

    private var pillColor: Color {
        switch finding.actionability {
        case .preApproved: return .green
        case .optIn: return .orange
        case .informational: return Color.white.opacity(0.6)
        }
    }

    /// Plain-button checkbox with an always-hittable shape — a clear fill
    /// alone is not tappable when unchecked (the Space Lens lesson).
    private var inclusionCheckbox: some View {
        Button(action: onToggleInclusion) {
            Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isIncluded ? Color.green : Color.white.opacity(0.45))
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isIncluded
                ? String(localized: "Included in Fix", comment: "Accessibility label for a checked care-card checkbox.")
                : String(localized: "Not included in Fix", comment: "Accessibility label for an unchecked care-card checkbox.")
        )
        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).toggle")
    }
}
