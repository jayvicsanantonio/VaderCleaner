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

    /// The step's screenshot, if one has actually been captured and added to
    /// the asset catalog. Resolved through `NSImage(named:)` rather than
    /// `Image(_:)` because SwiftUI's initializer renders a silent blank for a
    /// name that isn't there — the slots are meant to be empty until someone
    /// fills them, so a missing asset has to be detectable.
    private var screenshot: NSImage? {
        guard let name = content.screenshotAssetName, !name.isEmpty else { return nil }
        return NSImage(named: name)
    }

    /// A screenshot is a window capture, so it gets a landscape frame; the
    /// illustrated heroes keep their square one.
    private var heroSize: CGSize {
        screenshot == nil
            ? CGSize(width: 360, height: 360)
            : CGSize(width: 520, height: 300)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(content.theme.accent.opacity(0.42))
                .frame(width: 280, height: 280)
                .blur(radius: 95)

            artwork
        }
        .frame(width: heroSize.width, height: heroSize.height)
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
        if let screenshot {
            // Framed like a window rather than bled into the backdrop, so it
            // reads as a picture of the app instead of more chrome.
            Image(nsImage: screenshot)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                .padding(10)
        } else if let asset = content.heroAssetName, !asset.isEmpty {
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
        case .howItWorks:
            WelcomeLoop(beats: viewModel.step.beats, accent: content.theme.accent)
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

// MARK: - The loop

/// Scan → Review → Clean as three numbered beats joined by a rail, so the
/// order reads as a sequence rather than a list. Drawn entirely from shapes
/// and symbols: there is nothing here to re-capture when the UI changes.
struct WelcomeLoop: View {
    let beats: [WelcomeBeat]
    let accent: Color

    private let badgeSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(beats.enumerated()), id: \.offset) { index, beat in
                beatRow(beat, index: index, isLast: index == beats.count - 1)
                    .welcomeEntrance(index: index + 2)
            }
        }
    }

    private func beatRow(_ beat: WelcomeBeat, index: Int, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Badge over a connector that stops at the last beat, so the rail
            // reads as "then, then" rather than trailing off into nothing.
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(accent.deepenedForWhite)
                        .frame(width: badgeSize, height: badgeSize)
                        .shadow(color: accent.deepenedForWhite.opacity(0.45), radius: 7, y: 3)

                    Image(systemName: beat.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

                if !isLast {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.55), accent.opacity(0.15)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: badgeSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(beat.title)
                    .font(.system(size: 15, weight: .semibold))

                Text(beat.detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Breathing room under each beat, which also gives the connector
            // above something to span.
            .padding(.bottom, isLast ? 0 : 18)

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scan disc hint

/// The one-time pointer at the floating Scan disc, shown to a user who closed
/// the first-run flow without starting a scan. A single tap puts it away.
///
/// It sits in the main window rather than the disc's own child panel: that
/// panel is only a little larger than the disc itself, with no room for a
/// bubble above it.
struct WelcomeScanHint: View {
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        Button(action: onDismiss) {
            VStack(spacing: 6) {
                Text("Start here", comment: "First-run hint pointing at the floating Scan disc.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Text(
                    "Press the disc to scan. You'll see everything found before anything is cleaned.",
                    comment: "First-run hint body."
                )
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: 300)
            .glassEffect(.vaderTile, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : -8)
        .onAppear {
            guard !reduceMotion else {
                arrived = true
                return
            }
            withAnimation(.snappy(duration: 0.45, extraBounce: 0.15).delay(0.35)) {
                arrived = true
            }
        }
        .help(Text("Dismiss", comment: "Tooltip on the first-run Scan hint."))
        .accessibilityIdentifier("welcome.scanHint")
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
