// WelcomeViewSubviews.swift
// The pieces of the first-run flow: the glowing hero, each step's copy column, the Full Disk Access panel, the progress rail, and the staggered entrance they all share.

import SwiftUI

// MARK: - Hero

/// The step's artwork over a soft accent bloom — the same treatment the
/// section intros use, so the flow and the app share one look. Designer art
/// when the step has it, an accent-tinted SF Symbol otherwise.
struct WelcomeHero: View {
    let content: WelcomeStepContent
    /// The finish step's seal lands with a spring rather than a fade, so the
    /// end of the flow reads as an arrival.
    let isFinale: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        ZStack {
            Circle()
                .fill(content.theme.accent.opacity(0.42))
                .frame(width: 280, height: 280)
                .blur(radius: 95)

            artwork
        }
        .frame(width: 360, height: 360)
        .shadow(color: content.theme.accent.opacity(0.30), radius: 38)
        .scaleEffect(settled ? 1 : (isFinale ? 0.72 : 0.94))
        .opacity(settled ? 1 : 0)
        .onAppear {
            guard !reduceMotion else {
                settled = true
                return
            }
            withAnimation(isFinale ? .snappy(duration: 0.55, extraBounce: 0.28) : .smooth(duration: 0.5)) {
                settled = true
            }
        }
        // Decorative, but a sighted user gets a clear anchor here, so VoiceOver
        // gets one too — announced as artwork so it doesn't read as a duplicate
        // of the headline beside it.
        .accessibilityElement()
        .accessibilityLabel(Text(String(
            localized: "\(content.title) illustration",
            comment: "VoiceOver label for a first-run step's decorative hero art."
        )))
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private var artwork: some View {
        if let asset = content.heroAssetName, !asset.isEmpty {
            // Designer art is pre-coloured; only the bloom carries the accent.
            Image(asset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 300, height: 300)
        } else {
            Image(systemName: content.heroSymbol)
                .font(.system(size: 190, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(content.theme.accent)
        }
    }
}

// MARK: - Step column

/// A step's headline, tagline, and whatever it shows underneath — capability
/// rows on the tour, the permission panel on the access step, and short
/// reassurances on the two bookends. Every child rises into place in sequence.
struct WelcomeStepColumn: View {
    var viewModel: WelcomeViewModel

    private var content: WelcomeStepContent { viewModel.step.content }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(content.title)
                    .font(.system(size: 40, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .welcomeEntrance(index: 0)

                Text(content.tagline)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .welcomeEntrance(index: 1)
            }

            detail
        }
        .frame(width: 420, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(viewModel.step.accessibilityIdentifier)
    }

    @ViewBuilder
    private var detail: some View {
        switch viewModel.step {
        case .welcome:
            promises
        case .clean, .protect, .tune:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(content.features.enumerated()), id: \.offset) { index, feature in
                    WelcomeFeatureRow(feature: feature, accent: content.theme.accent)
                        .welcomeEntrance(index: index + 2)
                }
            }
        case .access:
            WelcomeAccessPanel(viewModel: viewModel)
                .welcomeEntrance(index: 2)
        case .ready:
            readySummary
        }
    }

    /// The three things worth promising before anyone has been asked for a
    /// permission: nothing leaves the Mac, nothing is deleted outright, and
    /// nothing happens without being shown first.
    private var promises: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.promiseLines.enumerated()), id: \.offset) { index, line in
                WelcomeCheckLine(text: line, accent: content.theme.accent)
                    .welcomeEntrance(index: index + 2)
            }
        }
    }

    private static let promiseLines: [String] = [
        String(
            localized: "Everything runs on your Mac — nothing is uploaded.",
            comment: "First-run flow: privacy promise."
        ),
        String(
            localized: "Your files go to the Trash, never straight to deletion.",
            comment: "First-run flow: safety promise."
        ),
        String(
            localized: "Every finding is shown to you before anything is touched.",
            comment: "First-run flow: transparency promise."
        ),
    ]

    /// A last read on where things stand, so the finish step is a summary
    /// rather than just a button.
    private var readySummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            WelcomeCheckLine(
                text: viewModel.hasFullDiskAccess
                    ? String(
                        localized: "Full Disk Access granted — scans will see everything.",
                        comment: "First-run flow: finish summary when access was granted."
                    )
                    : String(
                        localized: "Running without Full Disk Access — some results will be partial.",
                        comment: "First-run flow: finish summary when access was declined."
                    ),
                accent: content.theme.accent,
                isSatisfied: viewModel.hasFullDiskAccess
            )
            .welcomeEntrance(index: 2)

            WelcomeCheckLine(
                text: String(
                    localized: "Smart Scan covers junk, threats, and performance in one pass.",
                    comment: "First-run flow: finish summary."
                ),
                accent: content.theme.accent
            )
            .welcomeEntrance(index: 3)

            WelcomeCheckLine(
                text: String(
                    localized: "Live memory, storage, and temperature sit in your menu bar.",
                    comment: "First-run flow: finish summary."
                ),
                accent: content.theme.accent
            )
            .welcomeEntrance(index: 4)
        }
    }
}

// MARK: - Rows

/// One capability on the tour: an accent badge and its name, matching the
/// section intros' feature rows.
struct WelcomeFeatureRow: View {
    let feature: SectionFeature
    let accent: Color

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.deepenedForWhite,
                            accent.deepenedForWhite.opacity(0.72),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }
                .shadow(color: accent.deepenedForWhite.opacity(0.4), radius: 7, y: 3)

            Text(feature.title)
                .font(.system(size: 15, weight: .regular))

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A ticked line of reassurance. `isSatisfied` dims the tick for the one case
/// that is a caveat rather than a promise — running without Full Disk Access.
struct WelcomeCheckLine: View {
    let text: String
    let accent: Color
    var isSatisfied: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: isSatisfied ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSatisfied ? accent : Color.orange)

            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Full Disk Access panel

/// The permission step's body: a live status pill over the four steps it takes
/// to grant access. The pill flips itself when the flow's poll notices the
/// grant, so the user can walk back from System Settings to a done state.
struct WelcomeAccessPanel: View {
    var viewModel: WelcomeViewModel

    private static let grantSteps: [String] = [
        String(localized: "Open System Settings", comment: "First-run flow: Full Disk Access instruction."),
        String(
            localized: "Go to Privacy & Security → Full Disk Access",
            comment: "First-run flow: Full Disk Access instruction."
        ),
        String(localized: "Switch VaderCleaner on in the list", comment: "First-run flow: Full Disk Access instruction."),
        String(localized: "Come back here — this page notices", comment: "First-run flow: Full Disk Access instruction."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusPill

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.grantSteps.enumerated()), id: \.offset) { index, instruction in
                    HStack(spacing: 11) {
                        Image(systemName: "\(index + 1).circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))

                        Text(instruction)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .opacity(viewModel.hasFullDiskAccess ? 0.4 : 1)
            .padding(16)
            .glassEffect(.vaderTile, in: .rect(cornerRadius: 16))
        }
        .animation(VaderMotion.surface, value: viewModel.hasFullDiskAccess)
    }

    /// Reads "Waiting for access" until the grant lands, then springs into a
    /// green confirmation — the moment that tells the user the app is watching.
    private var statusPill: some View {
        HStack(spacing: 9) {
            Image(systemName: viewModel.hasFullDiskAccess ? "checkmark.circle.fill" : "hourglass")
                .font(.system(size: 14, weight: .semibold))

            Text(
                viewModel.hasFullDiskAccess
                    ? String(
                        localized: "Full Disk Access granted",
                        comment: "First-run flow: Full Disk Access status."
                    )
                    : String(
                        localized: "Waiting for access…",
                        comment: "First-run flow: Full Disk Access status."
                    )
            )
            .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(viewModel.hasFullDiskAccess ? Color.green : .white.opacity(0.7))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(
                viewModel.hasFullDiskAccess
                    ? Color.green.opacity(0.16)
                    : Color.white.opacity(0.08)
            )
        )
        .scaleEffect(viewModel.hasFullDiskAccess ? 1 : 0.98)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("welcome.accessStatus")
    }
}

// MARK: - Progress rail

/// One capsule per step: passed steps carry the accent, the current one
/// stretches, and the rest sit dim. Cheap enough to animate every step change
/// without a repeating clock.
struct WelcomeProgressRail: View {
    let step: WelcomeStep
    let accent: Color

    var body: some View {
        HStack(spacing: 7) {
            ForEach(WelcomeStep.allCases) { candidate in
                Capsule()
                    .fill(fill(for: candidate))
                    .frame(width: candidate == step ? 26 : 8, height: 8)
            }
        }
        .animation(VaderMotion.surface, value: step)
        .accessibilityElement()
        .accessibilityLabel(Text(String(
            localized: "Step \(step.rawValue + 1) of \(WelcomeStep.allCases.count)",
            comment: "VoiceOver label for the first-run flow's progress rail."
        )))
        .accessibilityValue(Text(step.content.title))
    }

    private func fill(for candidate: WelcomeStep) -> Color {
        if candidate == step { return accent }
        return candidate.rawValue < step.rawValue
            ? accent.opacity(0.55)
            : .white.opacity(0.18)
    }
}

// MARK: - Entrance

/// Rises a step's content into place, staggered by `index`, so the copy
/// assembles itself rather than appearing all at once. One-shot per step — the
/// column is `.id`-keyed, so every step change re-runs it. Reduce Motion drops
/// straight to the resting pose.
private struct WelcomeEntrance: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 14)
            .onAppear {
                guard !reduceMotion else {
                    arrived = true
                    return
                }
                withAnimation(.smooth(duration: 0.5).delay(0.16 + 0.07 * Double(index))) {
                    arrived = true
                }
            }
    }
}

extension View {
    /// Staggered rise-and-fade entrance for one line of a welcome step.
    func welcomeEntrance(index: Int) -> some View {
        modifier(WelcomeEntrance(index: index))
    }
}
