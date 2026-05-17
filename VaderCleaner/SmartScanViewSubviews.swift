// SmartScanViewSubviews.swift
// Dedicated subviews for the Smart Scan screen — idle, progress, the three-card results summary, done, and failed states.

import SwiftUI
import AppKit

// MARK: - Shared byte formatting

/// File-style byte formatter matching `ScanResult.formattedTotalSize`, so the
/// "freed" figure on the done screen reads the same way as the size the user
/// saw on the results card and as Finder reports sizes.
private let smartScanByteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.allowedUnits = .useAll
    f.countStyle = .file
    return f
}()

// MARK: - Idle

struct SmartScanIdleState: View {
    let onScan: () -> Void

    @State private var breathing = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            // The app icon is VaderCleaner's own artwork, so it doubles as the
            // hero render; the crimson bloom behind it ties it to the backdrop.
            // A slow scale breath keeps the welcome screen feeling alive while
            // it waits for the user to start a scan.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 168, height: 168)
                .shadow(color: Color.vaderCrimson.opacity(0.45), radius: 32)
                .scaleEffect(breathing ? 1.03 : 1.0)
                .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true),
                           value: breathing)
                .onAppear { breathing = true }

            Text(String(
                localized: "Welcome to VaderCleaner",
                comment: "Hero title on the idle Smart Scan welcome screen."
            ))
                .font(.system(size: 34, weight: .semibold))

            Text(String(
                localized: "Start with a quick and extensive scan of your Mac.",
                comment: "Subtitle on the idle Smart Scan welcome screen."
            ))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Spacer(minLength: 0)

            CircularActionButton(
                title: String(
                    localized: "Scan",
                    comment: "Primary button that starts the Smart Scan."
                ),
                accessibilityIdentifier: "smartScan.scan",
                action: onScan
            )
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// The hero / dashboard call to action — a crimson interactive-glass disc
/// echoing the reference's circular button. Interactive glass gives it the
/// system press-scale and shimmer; the crimson tint marks it as the primary
/// action. Shared by the welcome screen ("Scan") and the results dashboard
/// ("Clean") so the two CTAs stay visually identical.
private struct CircularActionButton: View {
    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void

    @State private var hovering = false
    @State private var pulsing = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 108, height: 108)
        }
        .buttonStyle(PressableCircleButtonStyle())
        .glassEffect(
            .regular.tint(Color.vaderCrimson).interactive(),
            in: .circle
        )
        // Ambient glow that breathes so the primary action keeps drawing the
        // eye even when the rest of the screen is still.
        .shadow(
            color: Color.vaderCrimson.opacity(pulsing ? 0.65 : 0.4),
            radius: pulsing ? 30 : 18,
            y: 8
        )
        .scaleEffect(hovering ? 1.06 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: hovering)
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulsing)
        .onHover { hovering = $0 }
        .onAppear { pulsing = true }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Press feedback for the circular CTAs — a quick spring scale-down while
/// pressed so the button feels physical rather than flat.
private struct PressableCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55),
                       value: configuration.isPressed)
    }
}

// MARK: - Progress

struct SmartScanProgressState: View {
    let label: String
    let identifier: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Failed

struct SmartScanFailedState: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(String(
                localized: "That scan couldn't complete",
                comment: "Heading on the Smart Scan failure screen."
            ))
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("smartScan.errorMessage")
            Button(String(
                localized: "Back to Smart Scan",
                comment: "Return button on the Smart Scan failure screen."
            ), action: onDismiss)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("smartScan.failurePrimary")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Results

/// One dashboard tile: category icon + title, a large metric number, a
/// caption, and an optional "Review" button that drills into that section.
/// The tiles never perform work themselves — the single circular CTA does —
/// so there are no per-card action buttons, only navigation.
private struct SmartScanMetricCard: View {
    let icon: String
    let tint: Color
    let title: String
    let metric: String
    let caption: String
    var reviewIdentifier: String?
    var onReview: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            Spacer(minLength: 8)
            Text(metric)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            HStack(alignment: .bottom) {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let reviewIdentifier, let onReview {
                    Button(String(
                        localized: "Review",
                        comment: "Per-card button on the Smart Scan dashboard that opens that section."
                    ), action: onReview)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(reviewIdentifier)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        // 12 matches HealthCard so the two dashboard card surfaces share one
        // corner radius.
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

/// One-shot entrance for the dashboard tiles: each fades and rises into place
/// with a per-index delay so the grid assembles in a quick cascade rather than
/// popping in all at once.
private struct StaggeredEntrance: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(
                .smooth(duration: 0.4).delay(Double(index) * 0.08),
                value: appeared
            )
    }
}

private extension View {
    func staggeredEntrance(index: Int, appeared: Bool) -> some View {
        modifier(StaggeredEntrance(index: index, appeared: appeared))
    }
}

/// The Smart Scan results dashboard: a "Start Over" bar, a metric-card grid,
/// and one circular CTA that runs the clean. Mirrors the reference's task
/// dashboard. There are deliberately no per-card checkboxes — the underlying
/// model has no selective-clean concept, and a checkbox that doesn't gate
/// anything would be misleading. Each card's "Review" drills into its full
/// section instead; the circular "Clean" performs the junk + threats pass.
struct SmartScanResultsState: View {
    let result: SmartScanResult
    let onClean: () -> Void
    let onReviewSystemJunk: () -> Void
    let onReviewMalware: () -> Void
    let onReviewOptimization: () -> Void
    let onStartOver: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    /// Drives the one-shot staggered entrance of the metric tiles when the
    /// dashboard first appears.
    @State private var appeared = false

    /// The circular CTA only appears when the clean would actually do
    /// something — junk to delete or threats to remove. Optimization is
    /// review-only and never contributes cleanable work.
    private var hasCleanableWork: Bool {
        result.totalJunkBytes > 0 || !result.threats.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onStartOver) {
                    Label(String(
                        localized: "Start Over",
                        comment: "Button on the Smart Scan dashboard that resets to the welcome screen."
                    ), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("smartScan.startOver")
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollView {
                VStack(spacing: 24) {
                    Text(String(
                        localized: "Your scan is ready. Here's what we found:",
                        comment: "Heading on the Smart Scan results dashboard."
                    ))
                        .font(.title3.weight(.medium))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("smartScan.resultsHeading")

                    // One container so the tiles sample each other's glass and
                    // refract consistently as the grid reflows on resize.
                    GlassEffectContainer(spacing: 16) {
                        LazyVGrid(columns: columns, spacing: 16) {
                            junkCard.staggeredEntrance(index: 0, appeared: appeared)
                            malwareCard.staggeredEntrance(index: 1, appeared: appeared)
                            optimizationCard.staggeredEntrance(index: 2, appeared: appeared)
                        }
                    }
                }
                .padding(24)
            }
            .onAppear { appeared = true }

            if hasCleanableWork {
                CircularActionButton(
                    title: String(
                        localized: "Clean",
                        comment: "Circular button on the Smart Scan dashboard that cleans junk and removes threats."
                    ),
                    accessibilityIdentifier: "smartScan.clean",
                    action: onClean
                )
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var junkCard: some View {
        SmartScanMetricCard(
            icon: "trash.fill",
            tint: .blue,
            title: String(
                localized: "System Junk",
                comment: "Smart Scan card title for the System Junk module."
            ),
            metric: result.junkResult.formattedTotalSize,
            caption: String(
                localized: "to clean",
                comment: "Caption under the System Junk metric on the Smart Scan dashboard."
            ),
            reviewIdentifier: "smartScan.reviewJunk",
            onReview: onReviewSystemJunk
        )
    }

    @ViewBuilder
    private var malwareCard: some View {
        if !result.clamAVAvailable {
            SmartScanMetricCard(
                icon: "shield.slash.fill",
                tint: .secondary,
                title: String(
                    localized: "Malware",
                    comment: "Smart Scan card title for the Malware module."
                ),
                metric: "—",
                caption: String(
                    localized: "ClamAV not installed",
                    comment: "Caption on the Smart Scan malware card when ClamAV is absent."
                )
            )
        } else if result.threats.isEmpty {
            SmartScanMetricCard(
                icon: "checkmark.shield.fill",
                tint: .green,
                title: String(
                    localized: "Malware",
                    comment: "Smart Scan card title for the Malware module."
                ),
                metric: "0",
                caption: String(
                    localized: "threats found",
                    comment: "Caption on the Smart Scan malware card after a clean scan."
                ),
                reviewIdentifier: "smartScan.reviewMalware",
                onReview: onReviewMalware
            )
        } else {
            SmartScanMetricCard(
                icon: "exclamationmark.shield.fill",
                tint: .red,
                title: String(
                    localized: "Malware",
                    comment: "Smart Scan card title for the Malware module."
                ),
                metric: "\(result.threats.count)",
                caption: result.threats.count == 1
                    ? String(
                        localized: "threat to remove",
                        comment: "Singular caption on the Smart Scan malware card when exactly one threat was found."
                    )
                    : String(
                        localized: "threats to remove",
                        comment: "Plural caption on the Smart Scan malware card when threats were found."
                    ),
                reviewIdentifier: "smartScan.reviewMalware",
                onReview: onReviewMalware
            )
        }
    }

    private var optimizationCard: some View {
        SmartScanMetricCard(
            icon: "slider.horizontal.3",
            tint: .orange,
            title: String(
                localized: "Optimization",
                comment: "Smart Scan card title for the Optimization module."
            ),
            metric: "\(result.optimizationItems.count)",
            caption: result.optimizationItems.count == 1
                ? String(
                    localized: "login item to review",
                    comment: "Singular caption under the Optimization metric when exactly one login item was found."
                )
                : String(
                    localized: "login items to review",
                    comment: "Plural caption under the Optimization metric on the Smart Scan dashboard."
                ),
            reviewIdentifier: "smartScan.review",
            onReview: onReviewOptimization
        )
    }
}

// MARK: - Done

struct SmartScanDoneState: View {
    let summary: SmartScanSummary
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(String(
                localized: "Smart Scan complete",
                comment: "Heading on the Smart Scan done screen."
            ))
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("smartScan.doneHeading")
            Text(summaryLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("smartScan.doneSummary")
            Button(String(
                localized: "Done",
                comment: "Button that returns to the idle Smart Scan screen."
            ), action: onDone)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("smartScan.doneButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var summaryLine: String {
        let freed = smartScanByteFormatter.string(fromByteCount: summary.bytesFreed)
        let threats = String.localizedStringWithFormat(
            String(
                localized: "Removed %d threats",
                comment: "Threat-count clause of the Smart Scan done summary; %d is a count. Pluralized via Localizable.stringsdict."
            ),
            summary.threatsRemoved
        )
        return String.localizedStringWithFormat(
            String(
                localized: "%@ freed. %@.",
                comment: "Smart Scan done summary; first %@ is a freed-bytes string, second %@ is the removed-threats clause."
            ),
            freed,
            threats
        )
    }
}
