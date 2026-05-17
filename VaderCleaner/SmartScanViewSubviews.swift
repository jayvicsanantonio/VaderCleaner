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

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            // The app icon is VaderCleaner's own artwork, so it doubles as the
            // hero render; the crimson bloom behind it ties it to the backdrop.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 168, height: 168)
                .shadow(color: Color.vaderCrimson.opacity(0.45), radius: 32)

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

            CircularScanButton(action: onScan)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// The hero call to action — a crimson interactive-glass disc echoing the
/// reference's circular Scan button. Interactive glass gives it the system
/// press-scale and shimmer; the crimson tint marks it as the primary action.
private struct CircularScanButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(String(
                localized: "Scan",
                comment: "Primary button that starts the Smart Scan."
            ))
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 108, height: 108)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.vaderCrimson).interactive(),
            in: .circle
        )
        .shadow(color: Color.vaderCrimson.opacity(0.5), radius: 22, y: 8)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("smartScan.scan")
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

/// One module summary card. `action` is optional — the Malware card hides its
/// button when ClamAV is absent or nothing was found, and the cards are purely
/// informational in that case.
private struct SmartScanCard: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var actionTitle: String?
    var actionIdentifier: String?
    var isDestructive: Bool = false
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let actionIdentifier, let action {
                Button(role: isDestructive ? .destructive : nil, action: action) {
                    Text(actionTitle)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(actionIdentifier)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }
}

struct SmartScanResultsState: View {
    let result: SmartScanResult
    let onClean: () -> Void
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                localized: "Scan complete",
                comment: "Heading on the Smart Scan results screen."
            ))
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("smartScan.resultsHeading")

            // One container so the three summary cards sample each other's
            // glass and refract consistently rather than as isolated surfaces.
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    junkCard
                    malwareCard
                    optimizationCard
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }

    private var junkCard: some View {
        let hasJunk = result.totalJunkBytes > 0
        return SmartScanCard(
            icon: "trash.fill",
            tint: .blue,
            title: String(
                localized: "System Junk",
                comment: "Smart Scan card title for the System Junk module."
            ),
            detail: result.junkResult.formattedTotalSize,
            actionTitle: hasJunk ? String(
                localized: "Clean",
                comment: "Button on the Smart Scan junk card that removes the scanned junk."
            ) : nil,
            actionIdentifier: "smartScan.clean",
            action: hasJunk ? onClean : nil
        )
    }

    @ViewBuilder
    private var malwareCard: some View {
        if !result.clamAVAvailable {
            SmartScanCard(
                icon: "shield.slash.fill",
                tint: .secondary,
                title: String(
                    localized: "Malware",
                    comment: "Smart Scan card title for the Malware module."
                ),
                detail: String(
                    localized: "ClamAV is not installed — malware was not scanned.",
                    comment: "Smart Scan malware card detail when ClamAV is absent."
                )
            )
        } else if result.threats.isEmpty {
            SmartScanCard(
                icon: "checkmark.shield.fill",
                tint: .green,
                title: String(
                    localized: "Malware",
                    comment: "Smart Scan card title for the Malware module."
                ),
                detail: String(
                    localized: "No threats found.",
                    comment: "Smart Scan malware card detail when the scan was clean."
                )
            )
        } else {
            SmartScanCard(
                icon: "exclamationmark.shield.fill",
                tint: .red,
                title: String(
                    localized: "Malware",
                    comment: "Smart Scan card title for the Malware module."
                ),
                detail: String.localizedStringWithFormat(
                    String(
                        localized: "%d threats found",
                        comment: "Smart Scan malware card detail; %d is a count. Pluralized via Localizable.stringsdict."
                    ),
                    result.threats.count
                ),
                actionTitle: String(
                    localized: "Remove",
                    comment: "Button on the Smart Scan malware card that removes detected threats."
                ),
                actionIdentifier: "smartScan.remove",
                isDestructive: true,
                action: onClean
            )
        }
    }

    private var optimizationCard: some View {
        SmartScanCard(
            icon: "slider.horizontal.3",
            tint: .orange,
            title: String(
                localized: "Optimization",
                comment: "Smart Scan card title for the Optimization module."
            ),
            detail: String.localizedStringWithFormat(
                String(
                    localized: "%d login items",
                    comment: "Smart Scan optimization card detail; %d is a count. Pluralized via Localizable.stringsdict."
                ),
                result.optimizationItems.count
            ),
            actionTitle: String(
                localized: "Review",
                comment: "Button on the Smart Scan optimization card that opens the full Optimization screen."
            ),
            actionIdentifier: "smartScan.review",
            action: onReview
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
