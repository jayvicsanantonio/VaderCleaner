// CarePlanFeedView.swift
// The results experience: a plain-language verdict hero over a zoned grid of care tiles — "Fix will handle these" (safe, pre-approved), "Worth a look" (the user's files, opt-in), and "Good to know" advisories.

import SwiftUI

/// The care-plan results shown when a scan lands, in the scanning grid's
/// visual language: glass tiles with each domain's 3D art glowing in its own
/// accent. Findings group into three zones by what Run may do — the zone
/// header states each tier's safety promise once, so every tile can stay
/// visual instead of repeating the same pill. The floating Fix disc (hosted
/// in a separate panel) is the one "fix it" action; tiles only toggle
/// inclusion or open Review.
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
            if let verdict = viewModel.verdict, let plan = viewModel.currentPlan {
                CareVerdictHero(
                    verdict: verdict,
                    // Pass the pre-approved count and its selected bytes so the
                    // hero speaks to exactly what Fix handles — agreeing with
                    // the tiles and the disc caption instead of counting opt-in
                    // items or promising the gross total found.
                    detail: CareVerdictEngine.detail(
                        for: plan,
                        readyCount: viewModel.preApprovedCount,
                        safeFreeableBytes: viewModel.preApprovedFreeableBytes
                    ),
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

        VStack(spacing: 26) {
            if !ready.isEmpty {
                zone(
                    title: String(localized: "Fix will handle these", comment: "Results zone header for pre-approved findings."),
                    subtitle: CareFindingCopy.safetyLine(for: .preApproved),
                    subtitleColor: .green,
                    findings: ready
                )
            }
            if !optIn.isEmpty {
                zone(
                    title: String(localized: "Worth a look", comment: "Results zone header for opt-in findings."),
                    subtitle: CareFindingCopy.safetyLine(for: .optIn),
                    subtitleColor: .orange,
                    findings: optIn
                )
            }
            if !info.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    zoneHeader(
                        title: String(localized: "Good to know", comment: "Results zone header for informational findings."),
                        subtitle: CareFindingCopy.safetyLine(for: .informational),
                        subtitleColor: .white.opacity(0.6)
                    )
                    ForEach(info) { finding in
                        CareAdvisoryChip(
                            finding: finding,
                            showsReview: reviewableKinds.contains(finding.kind),
                            onReview: { onRequestReview(finding.kind) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 960)
    }

    private func zone(
        title: String,
        subtitle: String,
        subtitleColor: Color,
        findings: [CareFinding]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            zoneHeader(title: title, subtitle: subtitle, subtitleColor: subtitleColor)
            LazyVGrid(columns: Self.gridColumns, spacing: 14) {
                ForEach(findings) { finding in
                    CareResultTile(
                        finding: finding,
                        metric: CareFindingCopy.metric(for: finding),
                        selectionNote: selectionNote(for: finding),
                        isIncluded: viewModel.isFindingIncluded(finding.kind),
                        showsReview: reviewableKinds.contains(finding.kind),
                        onToggleInclusion: { toggleInclusion(of: finding) },
                        onReview: { onRequestReview(finding.kind) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The tile's secondary line — how much of the finding is currently in the
    /// selection — shown beneath the total so the card reflects both what's
    /// there and what Fix will take. Matches the disc caption's "selected"
    /// scope. Informational advisories carry no selection, so they show none.
    private func selectionNote(for finding: CareFinding) -> String? {
        guard finding.actionability != .informational else { return nil }
        return CareFindingCopy.selectionNote(
            hasSize: finding.reclaimableBytes > 0,
            selectedBytes: viewModel.freeableBytes(for: finding.kind),
            selectedCount: viewModel.selectionCount(for: finding.kind)
        )
    }

    /// Turning an opt-in tile on with nothing selected silently selecting
    /// everything would betray the zone's promise — deep-link into Review so
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
    /// The supporting line, supplied by the feed so its freeable-bytes figure
    /// reflects the current selection rather than `verdict.detail`'s gross total.
    let detail: String
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
                    Text(detail)
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
        .frame(maxWidth: 960)
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

/// One finding's tile, in the scanning grid's visual language: the domain's
/// 3D art over its accent bloom in the top-right corner, title and
/// explanation left, big metric bottom-left, Review bottom-right, and an
/// inclusion checkbox for actionable findings.
struct CareResultTile: View {

    let finding: CareFinding
    /// The big metric — the finding's total size or item count.
    let metric: String
    /// The secondary line beneath it — how much is currently selected — so the
    /// tile shows both what's there and what Fix will take. `nil` hides it.
    let selectionNote: String?
    let isIncluded: Bool
    let showsReview: Bool
    let onToggleInclusion: () -> Void
    let onReview: () -> Void
    @Environment(\.sectionAccent) private var accent
    /// Lifts the inclusion checkbox on hover so it reads as a control, not a
    /// status glyph.
    @State private var hoveringCheckbox = false

    private var domain: CareDomain? { finding.kind.unit.domain }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if finding.actionability != .informational {
                    inclusionCheckbox
                }
                Text(CareFindingCopy.title(for: finding.kind))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // On-device Apple Intelligence explanation, availability-
                // gated inside the sparkle. Pure augmentation: the tile's
                // own copy is always the rendered text.
                SmartInsightsSparkle(
                    itemTitle: CareFindingCopy.title(for: finding.kind),
                    accent: accent,
                    topic: .careFinding
                )
            }
            // Clear the corner art so the copy never runs beneath it.
            .padding(.trailing, 64)
            Text(CareFindingCopy.explanation(for: finding.kind))
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 56)
            Spacer(minLength: 8)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                    if let selectionNote {
                        Text(selectionNote)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .monospacedDigit()
                            .lineLimit(1)
                            .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).selection")
                    }
                }
                Spacer(minLength: 8)
                if showsReview {
                    Button(action: onReview) {
                        Text(reviewTitle)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.vaderGlass)
                    .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).review")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(artCorner)
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
        .opacity(dimmed ? 0.75 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue)")
    }

    /// An actionable tile the user has left out of Fix mutes slightly, the
    /// same "not participating" read the scanning grid gives waiting tiles.
    private var dimmed: Bool {
        finding.actionability != .informational && !isIncluded
    }

    private var reviewTitle: String {
        finding.actionability == .optIn
            ? String(localized: "Choose What Goes", comment: "Review button title on opt-in care tiles.")
            : String(localized: "Review", comment: "Review button title on care tiles.")
    }

    /// The domain's art over its accent bloom — the same corner treatment as
    /// the scanning grid, so scan and results read as one surface.
    @ViewBuilder
    private var artCorner: some View {
        if let domain {
            RadialGradient(
                colors: [domain.artTint.opacity(dimmed ? 0.15 : 0.5), domain.artTint.opacity(0.0)],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 190
            )
            .overlay(alignment: .topTrailing) {
                Image(domain.artAsset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .padding(8)
                    .saturation(dimmed ? 0.3 : 1.0)
                    .opacity(dimmed ? 0.7 : 1.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .allowsHitTesting(false)
        }
    }

    /// Plain-button checkbox with an always-hittable shape — a clear fill
    /// alone is not tappable when unchecked (the Space Lens lesson). A square
    /// check (not a circle) and a hover lift read as a toggle you operate
    /// rather than a status stamp.
    private var inclusionCheckbox: some View {
        Button(action: onToggleInclusion) {
            Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isIncluded ? Color.green : Color.white.opacity(hoveringCheckbox ? 0.85 : 0.55))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(hoveringCheckbox ? 0.12 : 0.001))
                )
                .contentShape(Rectangle())
                .scaleEffect(hoveringCheckbox ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hoveringCheckbox)
        }
        .buttonStyle(.plain)
        .onHover { hoveringCheckbox = $0 }
        .help(isIncluded
            ? String(localized: "Leave this out of Fix", comment: "Tooltip on a checked care-tile checkbox.")
            : String(localized: "Include this in Fix", comment: "Tooltip on an unchecked care-tile checkbox.")
        )
        .accessibilityLabel(
            isIncluded
                ? String(localized: "Included in Fix", comment: "Accessibility label for a checked care-tile checkbox.")
                : String(localized: "Not included in Fix", comment: "Accessibility label for an unchecked care-tile checkbox.")
        )
        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).toggle")
    }
}

/// A slim full-width row for an informational finding: icon, title, metric,
/// and Review where one exists. Nothing here is ever removed, so it reads as
/// a note, not a task.
private struct CareAdvisoryChip: View {

    let finding: CareFinding
    let showsReview: Bool
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text(CareFindingCopy.title(for: finding.kind))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Text(CareFindingCopy.metric(for: finding))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
            if showsReview {
                Button(action: onReview) {
                    Text(String(localized: "Have a Look", comment: "Review button title on an advisory chip."))
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.vaderGlass)
                .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue).review")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vaderTileGlass()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.card.\(finding.kind.rawValue)")
    }

    private var iconName: String {
        switch finding.kind {
        case .lowDiskSpace: return "externaldrive.fill.badge.exclamationmark"
        case .loginItems: return "power"
        default: return "info.circle"
        }
    }
}
