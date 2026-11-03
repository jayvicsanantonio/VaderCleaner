// CarePlanFeedView.swift
// The results experience: a summary hero stating what Fix will clean and where it goes, over a compact "Ready to clean" checklist, "Your call" cards for the user's own files, and "Just so you know" chips.

import SwiftUI
import VaderCleanerCore

/// The care-plan results shown when a scan lands. Findings group into three
/// zones by what Run may do — the zone header states each tier's safety
/// promise once, so rows and cards can stay short. The hero leads with the one
/// total Fix acts on, so the hero, every row, and the Fix disc's caption
/// agree. The floating Fix disc (hosted in a separate panel) is the one "fix
/// it" action; rows only toggle inclusion or open Review.
struct CarePlanFeedView: View {

    var viewModel: SmartScanViewModel
    /// Kinds whose Review screen exists; tiles for other kinds hide the
    /// Review affordance rather than dead-ending.
    let reviewableKinds: Set<CareFinding.Kind>
    let onRequestReview: (CareFinding.Kind) -> Void
    let onStartOver: () -> Void
    @Environment(\.sectionAccent) private var accent
    /// Optional so previews and tests need not inject a store.
    @Environment(CareHistoryStore.self) private var history: CareHistoryStore?

    private static let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
        count: 2
    )

    private static let chipColumns = [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .leading)]

    /// Bottom breathing room reserved below the last tile so the floating Fix
    /// disc — and the scope caption now sitting above it — never rest over a
    /// card. Sized to clear the disc panel's reach above the window edge with a
    /// comfortable margin.
    private static let discBottomClearance: CGFloat = 168

    var body: some View {
        ScrollView {
            // One glass container for the hero and every tile: independent
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
        VStack(spacing: 22) {
            topBar
            if viewModel.isRefreshingFindings {
                refreshingNote
            }
            if let verdict = viewModel.verdict, let plan = viewModel.currentPlan {
                CareRunHero(
                    verdict: verdict,
                    summary: viewModel.runSummary,
                    // Speaks only when Fix has nothing to do, so the hero
                    // still explains an opt-in-only or all-clear plan.
                    fallbackDetail: CareVerdictEngine.detail(
                        for: plan,
                        readyCount: viewModel.preApprovedCount,
                        safeFreeableBytes: viewModel.preApprovedFreeableBytes
                    ),
                    historyLine: history?.lifetimeFreedLine(),
                    coverageNote: coverageNote
                )
            }
            // An empty feed mid-re-check isn't an all-clear — the findings being
            // re-scanned are simply not back yet. The note above says so.
            if viewModel.rankedFindings.isEmpty && !viewModel.isRefreshingFindings {
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
                zones
            }
            Spacer(minLength: Self.discBottomClearance)
        }
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .frame(maxWidth: .infinity)
    }

    /// The three safety zones, each rendered only when it has findings.
    @ViewBuilder
    private var zones: some View {
        let ready = viewModel.rankedFindings.filter { $0.actionability == .preApproved }
        let optIn = viewModel.rankedFindings.filter { $0.actionability == .optIn }
        let info = viewModel.rankedFindings.filter { $0.actionability == .informational }

        VStack(spacing: 28) {
            if !ready.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    zoneHeader(
                        title: String(localized: "Ready to clean", comment: "Results zone header for pre-approved findings."),
                        subtitle: CareFindingCopy.safetyLine(for: .preApproved),
                        subtitleColor: .green
                    )
                    readyList(ready)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !optIn.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    zoneHeader(
                        title: String(localized: "Your call", comment: "Results zone header for opt-in findings."),
                        subtitle: CareFindingCopy.safetyLine(for: .optIn),
                        subtitleColor: .orange
                    )
                    LazyVGrid(columns: Self.gridColumns, spacing: 14) {
                        ForEach(optIn) { finding in
                            choiceCard(finding)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !info.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    zoneHeader(
                        title: String(localized: "Good to know", comment: "Results zone header for informational findings."),
                        subtitle: CareFindingCopy.safetyLine(for: .informational),
                        subtitleColor: .white.opacity(0.6)
                    )
                    LazyVGrid(columns: Self.chipColumns, alignment: .leading, spacing: 10) {
                        ForEach(info) { finding in
                            CareAdvisoryChip(
                                finding: finding,
                                showsReview: reviewableKinds.contains(finding.kind),
                                onReview: { onRequestReview(finding.kind) }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 960)
    }

    /// The pre-approved findings as one checklist: they are already decided,
    /// so each needs a glance and a checkbox rather than a card of its own.
    private func readyList(_ findings: [CareFinding]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.1))
                        .frame(height: 1)
                        .padding(.leading, 98)
                }
                readyRow(finding)
            }
        }
        .padding(.vertical, 4)
        .vaderTileGlass()
    }

    private func readyRow(_ finding: CareFinding) -> some View {
        let severity = viewModel.severity(for: finding)
        return CareReadyRow(
            finding: finding,
            amount: CareFindingCopy.rowAmount(
                for: finding,
                selectedBytes: viewModel.freeableBytes(for: finding.kind),
                selectedCount: viewModel.selectionCount(for: finding.kind)
            ),
            severityNote: CareFindingCopy.severityNote(for: severity.signals),
            isCritical: severity.urgency == .critical,
            isIncluded: viewModel.isFindingIncluded(finding.kind),
            showsReview: reviewableKinds.contains(finding.kind),
            onToggleInclusion: { viewModel.setFindingIncluded(finding.kind, !viewModel.isFindingIncluded(finding.kind)) },
            onReview: { onRequestReview(finding.kind) }
        )
    }

    private func choiceCard(_ finding: CareFinding) -> some View {
        let severity = viewModel.severity(for: finding)
        let pickedCount = viewModel.selectionCount(for: finding.kind)
        return CareChoiceCard(
            finding: finding,
            pickedNote: CareFindingCopy.pickedNote(
                hasSize: finding.reclaimableBytes > 0,
                selectedBytes: viewModel.freeableBytes(for: finding.kind),
                selectedCount: pickedCount
            ),
            isPicked: viewModel.isFindingIncluded(finding.kind) && pickedCount > 0,
            severityNote: CareFindingCopy.severityNote(for: severity.signals),
            isCritical: severity.urgency == .critical,
            showsReview: reviewableKinds.contains(finding.kind),
            onReview: { onRequestReview(finding.kind) }
        )
    }

    /// A zone's safety promise, stated once so the tiles below stay clean.
    private func zoneHeader(title: String, subtitle: String, subtitleColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(subtitleColor)
        }
        .padding(.leading, 4)
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
        .frame(maxWidth: 960)
    }

    /// Shown while a post-Fix re-check runs. The cards the pass cleaned are off
    /// the feed until their re-scan lands, and this says why rather than leaving
    /// the gap unexplained.
    private var refreshingNote: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(
                localized: "Re-checking what Fix changed…",
                comment: "Feed note shown while the findings a Fix pass acted on are re-scanned."
            ))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: 960, alignment: .leading)
        .accessibilityIdentifier("smartScan.refreshingNote")
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
}

/// The summary hero: the verdict as a small status line, then the one total
/// Fix will clean, a bar splitting it into what is deleted now and what goes
/// to the Trash, and the plan in a line. With nothing for Fix to do it falls
/// back to the verdict's own headline and detail.
private struct CareRunHero: View {

    let verdict: CareVerdict
    let summary: CareRunSummary
    /// The verdict's supporting line, shown only when Fix has nothing to do.
    let fallbackDetail: String
    let historyLine: String?
    let coverageNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let headline = summary.headline {
                statusLine
                Text(headline)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("smartScan.runSummary")
                if summary.totalBytes > 0 {
                    CareSplitBar(deletedFraction: summary.deletedFraction)
                        .padding(.top, 2)
                }
                if let breakdown = summary.breakdown {
                    Text(breakdown)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                        .accessibilityIdentifier("smartScan.runBreakdown")
                }
                if let planLine = summary.planLine {
                    Text(planLine)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityIdentifier("smartScan.verdictDetail")
                }
            } else {
                Text(verdict.headline)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("smartScan.verdictHeading")
                Text(fallbackDetail)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityIdentifier("smartScan.verdictDetail")
            }
            if let historyLine {
                Text(historyLine)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityIdentifier("smartScan.historyLine")
            }
            if let coverageNote {
                Text(coverageNote)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.9))
                    .accessibilityIdentifier("smartScan.coverageNote")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .frame(maxWidth: 960)
        .vaderTileGlass()
    }

    /// The verdict, demoted to an eyebrow: a status dot in the tier's color and
    /// the headline in words, so a threat still announces itself above the total.
    private var statusLine: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verdict.headline)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityIdentifier("smartScan.verdictHeading")
        }
    }

    private var statusColor: Color {
        switch verdict.status {
        case .critical: return .red
        case .requiresAttention: return .orange
        case .fair: return .yellow
        case .good: return .green
        case .excellent: return .mint
        }
    }
}

/// The hero's two-part bar: the solid share is deleted now, the faint share
/// waits in the Trash. A sliver of a share still shows, so a 3% deletion
/// doesn't vanish next to the rest.
private struct CareSplitBar: View {

    let deletedFraction: Double

    var body: some View {
        GeometryReader { proxy in
            let shown = deletedFraction > 0 ? max(deletedFraction, 0.015) : 0
            HStack(spacing: 2) {
                if shown > 0 {
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * shown)
                }
                if deletedFraction < 1 {
                    Capsule()
                        .fill(.white.opacity(0.32))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// One pre-approved finding as a checklist row: checkbox, the domain's art,
/// title and a one-line summary, then the amount Fix takes and Review.
private struct CareReadyRow: View {

    let finding: CareFinding
    let amount: CareRowAmount
    /// Why this row ranks where it does, when something other than its plain
    /// size put it there. `nil` for a finding with nothing special to say.
    let severityNote: String?
    /// Whether severity resolved this finding to critical — the tier the red
    /// edge marks.
    let isCritical: Bool
    let isIncluded: Bool
    let showsReview: Bool
    let onToggleInclusion: () -> Void
    let onReview: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            CareInclusionCheckbox(isIncluded: isIncluded, kind: finding.kind, action: onToggleInclusion)
            CareDomainArt(domain: finding.kind.unit.domain, size: 36, dimmed: !isIncluded)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(CareFindingCopy.title(for: finding.kind))
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    // On-device Apple Intelligence explanation, availability-
                    // gated inside the sparkle. Pure augmentation: the row's
                    // own copy is always the rendered text.
                    SmartInsightsSparkle(
                        itemTitle: CareFindingCopy.title(for: finding.kind),
                        accent: accent,
                        topic: .careFinding
                    )
                }
                Text(CareFindingCopy.summary(for: finding.kind))
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                if let severityNote {
                    Text(severityNote)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).severity")
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(amount.primary)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)
                if let secondary = amount.secondary {
                    Text(secondary)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                        .lineLimit(1)
                        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).selection")
                }
            }
            .frame(minWidth: 90, alignment: .trailing)
            if showsReview {
                Button(action: onReview) {
                    Text(String(localized: "Review", comment: "Review button title on care tiles."))
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.vaderGlass)
                .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).review")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isIncluded ? 1 : 0.6)
        .overlay(alignment: .leading) {
            if isCritical {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.red)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue)")
    }
}

/// One opt-in finding as a card: the user's own files, so nothing is chosen
/// until they pick in Review. There is no checkbox — ticking one would read as
/// "remove all of it" — only the amount found, what is picked so far, and the
/// way into Review.
private struct CareChoiceCard: View {

    let finding: CareFinding
    let pickedNote: String
    let isPicked: Bool
    let severityNote: String?
    let isCritical: Bool
    let showsReview: Bool
    let onReview: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(CareFindingCopy.title(for: finding.kind))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        SmartInsightsSparkle(
                            itemTitle: CareFindingCopy.title(for: finding.kind),
                            accent: accent,
                            topic: .careFinding
                        )
                    }
                    Text(CareFindingCopy.summary(for: finding.kind))
                        .font(.system(size: 12.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                CareDomainArt(domain: finding.kind.unit.domain, size: 44, dimmed: !isPicked)
            }
            if let severityNote {
                Text(severityNote)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).severity")
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(CareFindingCopy.metric(for: finding))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(pickedNote)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isPicked ? Color.green : .white.opacity(0.55))
                        .monospacedDigit()
                        .lineLimit(1)
                        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).selection")
                }
                Spacer(minLength: 8)
                if showsReview {
                    Button(action: onReview) {
                        Text(isPicked
                            ? String(localized: "Change", comment: "Your-call card button once the user has picked something.")
                            : String(localized: "Choose What Goes", comment: "Review button title on opt-in care tiles.")
                        )
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.vaderGlass)
                    .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).review")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .vaderTileGlass()
        .overlay {
            if isPicked {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.55), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if isCritical {
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
}

/// The domain's 3D art over a soft bloom in its tint — the scanning grid's
/// corner treatment, shrunk to sit beside a row's title.
private struct CareDomainArt: View {

    let domain: CareDomain?
    let size: CGFloat
    let dimmed: Bool

    var body: some View {
        ZStack {
            if let domain {
                RadialGradient(
                    colors: [domain.artTint.opacity(dimmed ? 0.15 : 0.5), domain.artTint.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.75
                )
                .frame(width: size * 1.5, height: size * 1.5)
                Image(domain.artAsset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .saturation(dimmed ? 0.3 : 1.0)
                    .opacity(dimmed ? 0.7 : 1.0)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Plain-button checkbox with an always-hittable shape — a clear fill
/// alone is not tappable when unchecked (the Space Lens lesson). A square
/// check (not a circle) and a hover lift read as a toggle you operate
/// rather than a status stamp.
private struct CareInclusionCheckbox: View {

    let isIncluded: Bool
    let kind: CareFinding.Kind
    let action: () -> Void
    /// Lifts the checkbox on hover so it reads as a control, not a status glyph.
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isIncluded ? Color.green : Color.white.opacity(hovering ? 0.85 : 0.55))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.12 : 0.001))
                )
                .contentShape(Rectangle())
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isIncluded
            ? String(localized: "Leave this out of Fix", comment: "Tooltip on a checked care-tile checkbox.")
            : String(localized: "Include this in Fix", comment: "Tooltip on an unchecked care-tile checkbox.")
        )
        .accessibilityLabel(
            isIncluded
                ? String(localized: "Included in Fix", comment: "Accessibility label for a checked care-tile checkbox.")
                : String(localized: "Not included in Fix", comment: "Accessibility label for an unchecked care-tile checkbox.")
        )
        .accessibilityIdentifier("smartScan.card.\(kind.rawValue).toggle")
    }
}

/// A compact chip for an informational finding: icon, title, and count, and
/// the whole chip opens Review where one exists. Nothing here is ever removed,
/// so it reads as a note, not a task.
private struct CareAdvisoryChip: View {

    let finding: CareFinding
    let showsReview: Bool
    let onReview: () -> Void

    var body: some View {
        Group {
            if showsReview {
                Button(action: onReview) { content }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).review")
            } else {
                content
            }
        }
        .vaderTileGlass()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue)")
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(CareFindingCopy.title(for: finding.kind))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(CareFindingCopy.metric(for: finding))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if showsReview {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch finding.kind {
        case .lowDiskSpace: return "externaldrive.fill.badge.exclamationmark"
        case .loginItems: return "power"
        case .extensions: return "puzzlepiece.extension"
        case .backgroundItems: return "gearshape.2"
        default: return "info.circle"
        }
    }
}
