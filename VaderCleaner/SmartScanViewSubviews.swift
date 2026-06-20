// SmartScanViewSubviews.swift
// Dedicated subviews for the Smart Scan screen — progress, the three-card results dashboard, done, and failed states.

import SwiftUI

// MARK: - Progress

struct SmartScanProgressState: View {
    let label: String
    let identifier: String
    /// Optional live progress line (e.g. "12,431 items") shown beneath the
    /// status phrase so the user sees the composite scan advancing.
    var detail: String? = nil
    /// Rotating personality phrases for the open scan; falls back to `label`.
    var phrases: [String]? = nil

    var body: some View {
        VStack(spacing: 16) {
            ScanProgressIndicator()
            ScanningStatusView(
                phrases: phrases ?? [label],
                count: detail,
                countIdentifier: "\(identifier).count"
            )
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

/// One dashboard tile, modelled on the reference Smart Care card: the section's
/// 3D art sits in the top-right corner over a soft accent bloom, an opt-in
/// checkbox and title sit top-left, a large metric and small caption sit
/// bottom-left, and a translucent "Review" button anchors bottom-right. The
/// single circular CTA performs the actual work — each tile's checkbox gates
/// whether that module participates in Run.
///
/// Three independent presentation switches:
///   * `selection` nil → no checkbox (zero-work tiles, e.g. "No vital
///     updates").
///   * `selection.wrappedValue == false` → tile dims and Review is hidden
///     (matches the reference's gray state for deselected modules).
///   * `onReview` nil → Review button is hidden (zero-work tiles have
///     nothing to review).
private struct SmartScanMetricCard: View {
    /// Asset-catalog name of the section's pre-coloured 3D art for the corner.
    let assetName: String
    /// The section's accent — drives the soft corner bloom behind the art.
    let tint: Color
    let title: String
    let metric: String
    let caption: String
    var selection: Binding<Bool>? = nil
    var checkboxIdentifier: String? = nil
    var reviewIdentifier: String? = nil
    var onReview: (() -> Void)?

    private var isDeselected: Bool {
        if let selection { return !selection.wrappedValue }
        return false
    }

    /// Corner radius shared by the content clip and the glass shape so the two
    /// stay concentric — a mismatch is what leaves a seam at the corners.
    private let cornerRadius: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topLeading) {
            cornerArt
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Clip the corner art + content to the rounded rect *before* the glass,
        // so the square radial bloom doesn't spill past the corners. The glass
        // is applied last and left un-clipped: re-clipping it with the same
        // shape crops its specular highlight rim, which Liquid Glass paints
        // strongest along the top edge — that crop is the hard bright seam that
        // showed at the top-right corner.
        .clipShape(.rect(cornerRadius: cornerRadius))
        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        // A deselected tile reads as "off" by losing its colour rather than
        // fading toward the backdrop: the corner bloom and art desaturate (see
        // `cornerArt`) and the whole card dims just slightly so it stays
        // legible. A heavy transparency wash would make the metric hard to read
        // and let the busy backdrop bleed through.
        .opacity(isDeselected ? 0.9 : 1.0)
        .animation(.smooth(duration: 0.25), value: isDeselected)
    }

    /// The section's art in the top-right corner over a soft accent bloom that
    /// bleeds out of the corner, giving each tile its own colour glow. When the
    /// tile is deselected the bloom fades out and the art desaturates, so the
    /// card reads as muted/inactive — matching the dimmed, greyed-out look of an
    /// unchecked tile in the reference design.
    private var cornerArt: some View {
        RadialGradient(
            colors: [tint.opacity(isDeselected ? 0.0 : 0.55), tint.opacity(0.0)],
            center: .topTrailing,
            startRadius: 0,
            endRadius: 240
        )
        .overlay(alignment: .topTrailing) {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 132, height: 132)
                .padding(6)
                .saturation(isDeselected ? 0.0 : 1.0)
                .opacity(isDeselected ? 0.55 : 1.0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let selection {
                    Toggle("", isOn: selection)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityIdentifier(checkboxIdentifier ?? "")
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 12)
            Text(metric)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
            HStack(alignment: .bottom) {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                reviewButton
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Translucent pill rather than an accent-filled button, matching the
    /// reference. Rendered unconditionally so deselecting a tile doesn't pop it
    /// out of the layout (which would shift the card footprint) — when the tile
    /// is deselected, or has no Review, it stays in the tree but invisible and
    /// non-interactive, and is hidden from assistive tech.
    @ViewBuilder
    private var reviewButton: some View {
        if let reviewIdentifier, let onReview {
            Button(action: onReview) {
                Text(String(
                    localized: "Review",
                    comment: "Per-card button on the Smart Scan dashboard that opens that tile's manager screen."
                ))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(.white.opacity(0.15), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(reviewIdentifier)
            .opacity(isDeselected ? 0 : 1)
            .allowsHitTesting(!isDeselected)
            .accessibilityHidden(isDeselected)
        }
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

/// The Smart Scan results dashboard, mirroring CleanMyMac Smart Care's layout:
/// a "Start Over" bar top-left and a five-tile metric grid with per-tile
/// opt-in checkboxes. The Run CTA lives in the same borderless child panel
/// as the Scan disc (see `FloatingRunOverlay` + `ScanDiscWindowController`)
/// so it straddles the window's bottom edge with matching size and
/// position. The dashboard reserves bottom padding so the floating Run disc
/// never overlaps the bottom-most grid row.
struct SmartScanResultsState: View {
    var viewModel: SmartScanViewModel
    let result: SmartScanResult
    let onRequestReview: (SmartScanModule) -> Void
    let onStartOver: () -> Void

    /// Drives the one-shot staggered entrance of the metric tiles when the
    /// dashboard first appears.
    @State private var appeared = false

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

            VStack(spacing: 24) {
                Text(String(
                    localized: "Your tasks are ready to run. Look what we found:",
                    comment: "Heading on the Smart Scan results dashboard."
                ))
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("smartScan.resultsHeading")

                // Three tiles on top, two wider tiles beneath — the reference's
                // 3 + 2 arrangement. Both rows divide the available height so
                // the grid fills the pane without scrolling. One container so
                // the tiles sample each other's glass and refract consistently.
                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            tileEntry(.systemJunk, index: 0)
                            tileEntry(.malware, index: 1)
                            tileEntry(.optimization, index: 2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        HStack(spacing: 16) {
                            tileEntry(.applications, index: 3)
                            tileEntry(.myClutter, index: 4)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            // Reserve the bottom band for the floating Run disc, so the last
            // grid row never sits under it. Mirrors the SectionIntroView's
            // `.padding(.bottom, 168)` reservation for the Scan disc.
            .padding(.bottom, 168)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared = true }
    }

    /// One grid cell: the module's tile, framed to fill its share of the row and
    /// given a staggered entrance.
    private func tileEntry(_ module: SmartScanModule, index: Int) -> some View {
        tile(for: module)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .staggeredEntrance(index: index, appeared: appeared)
    }

    /// Whether the given module would actually produce work if Run were
    /// pressed right now. Delegates to `SmartScanViewModel.willExecute(_:)`
    /// so per-tile caption decisions and the floating Run disc's visibility
    /// gate share one source of truth.
    private func willExecute(_ module: SmartScanModule) -> Bool {
        viewModel.willExecute(module)
    }

    @ViewBuilder
    private func tile(for module: SmartScanModule) -> some View {
        switch module {
        case .systemJunk:
            systemJunkTile
        case .malware:
            malwareTile
        case .optimization:
            optimizationTile
        case .applications:
            applicationsTile
        case .myClutter:
            myClutterTile
        }
    }

    /// Binding bridge from the view-model's `Set<SmartScanModule>` to a
    /// per-tile `Toggle`. Reading checks set membership; writing flips it,
    /// regardless of the incoming bool (`Toggle` always passes the inverse).
    private func tileBinding(_ module: SmartScanModule) -> Binding<Bool> {
        Binding(
            get: { viewModel.isModuleSelected(module) },
            set: { _ in viewModel.toggleModule(module) }
        )
    }

    // MARK: Per-tile views

    private var systemJunkTile: some View {
        let hasWork = result.totalJunkBytes > 0
        return SmartScanMetricCard(
            assetName: "systemJunk",
            tint: NavigationSection.systemJunk.theme.accent,
            title: String(
                localized: "System Junk",
                comment: "Smart Scan card title for the System Junk module."
            ),
            metric: hasWork
                ? result.junkResult.formattedTotalSize
                : String(
                    localized: "0 KB",
                    comment: "Zero-work caption metric on the Smart Scan System Junk card."
                ),
            caption: hasWork
                ? String(
                    localized: "to clean",
                    comment: "Caption under the System Junk metric on the Smart Scan dashboard."
                )
                : String(
                    localized: "no junk found",
                    comment: "Zero-work caption on the Smart Scan System Junk card."
                ),
            selection: hasWork ? tileBinding(.systemJunk) : nil,
            checkboxIdentifier: "smartScan.toggleJunk",
            reviewIdentifier: hasWork ? "smartScan.reviewJunk" : nil,
            onReview: hasWork ? { onRequestReview(.systemJunk) } : nil
        )
    }

    @ViewBuilder
    private var malwareTile: some View {
        if !result.clamAVAvailable {
            SmartScanMetricCard(
                assetName: "malwareRemoval",
                tint: NavigationSection.malwareRemoval.theme.accent,
                title: String(
                    localized: "Protection",
                    comment: "Smart Scan card title for the Malware module."
                ),
                metric: "—",
                caption: String(
                    localized: "Antivirus engine not installed",
                    comment: "Caption on the Smart Scan malware card when ClamAV is absent."
                )
            )
        } else if result.threats.isEmpty {
            SmartScanMetricCard(
                assetName: "malwareRemoval",
                tint: NavigationSection.malwareRemoval.theme.accent,
                title: String(
                    localized: "Protection",
                    comment: "Smart Scan card title for the Malware module."
                ),
                metric: "0",
                caption: String(
                    localized: "threats found",
                    comment: "Caption on the Smart Scan malware card after a clean scan."
                )
            )
        } else {
            SmartScanMetricCard(
                assetName: "malwareRemoval",
                tint: NavigationSection.malwareRemoval.theme.accent,
                title: String(
                    localized: "Protection",
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
                selection: tileBinding(.malware),
                checkboxIdentifier: "smartScan.toggleMalware",
                reviewIdentifier: "smartScan.reviewMalware",
                onReview: { onRequestReview(.malware) }
            )
        }
    }

    private var optimizationTile: some View {
        // Performance is always actionable — maintenance scripts run on
        // every macOS install — so this tile never collapses to a zero-work
        // variant. The login-item count is informational; Run's actual work
        // here is `MaintenanceScriptRunner`.
        SmartScanMetricCard(
            assetName: "optimization",
            tint: NavigationSection.optimization.theme.accent,
            title: String(
                localized: "Performance",
                comment: "Smart Scan card title for the Optimization module."
            ),
            metric: String(
                localized: "1 task",
                comment: "Smart Scan Performance card metric — maintenance scripts run as a single task."
            ),
            caption: String(
                localized: "to run",
                comment: "Caption under the Performance metric on the Smart Scan dashboard."
            ),
            selection: tileBinding(.optimization),
            checkboxIdentifier: "smartScan.toggleOptimization",
            reviewIdentifier: "smartScan.review",
            onReview: { onRequestReview(.optimization) }
        )
    }

    private var applicationsTile: some View {
        let count = result.availableUpdates.count
        let hasWork = count > 0
        return SmartScanMetricCard(
            assetName: "applications",
            tint: NavigationSection.applications.theme.accent,
            title: String(
                localized: "Applications",
                comment: "Smart Scan card title for the App Updater module."
            ),
            metric: hasWork
                ? "\(count)"
                : String(
                    localized: "No vital updates",
                    comment: "Zero-work metric on the Smart Scan Applications card — no app updates available."
                ),
            caption: hasWork
                ? (count == 1
                    ? String(
                        localized: "update to install",
                        comment: "Singular caption on the Smart Scan Applications card when exactly one update was found."
                    )
                    : String(
                        localized: "updates to install",
                        comment: "Plural caption on the Smart Scan Applications card when multiple updates were found."
                    ))
                : String(
                    localized: "to install",
                    comment: "Zero-work caption on the Smart Scan Applications card."
                ),
            selection: hasWork ? tileBinding(.applications) : nil,
            checkboxIdentifier: "smartScan.toggleApplications",
            reviewIdentifier: hasWork ? "smartScan.reviewApplications" : nil,
            onReview: hasWork ? { onRequestReview(.applications) } : nil
        )
    }

    private var myClutterTile: some View {
        let count = result.largeOldFiles.count
        let hasWork = count > 0
        // When the tile is checked but no individual file is opted in, the
        // caption nudges the user to Review and pick — Run would otherwise
        // silently skip the tile (large-file deletion is opt-in per
        // `largeFileSelection`).
        let selectedCount = viewModel.largeFileSelection.count
        let captionWhenWork: String = selectedCount == 0
            ? String(
                localized: "Tap Review to pick files",
                comment: "Caption on the Smart Scan My Clutter card when files were found but none have been selected for removal."
            )
            : (selectedCount == 1
                ? String(
                    localized: "1 file selected",
                    comment: "Singular caption on the Smart Scan My Clutter card when one file has been opted in for removal."
                )
                : String.localizedStringWithFormat(
                    String(
                        localized: "%d files selected",
                        comment: "Plural caption on the Smart Scan My Clutter card; %d is a count."
                    ),
                    selectedCount
                ))
        return SmartScanMetricCard(
            assetName: "largeOldFiles",
            tint: NavigationSection.largeOldFiles.theme.accent,
            title: String(
                localized: "My Clutter",
                comment: "Smart Scan card title for the Large & Old Files module."
            ),
            metric: hasWork
                ? (count == 1
                    ? String(
                        localized: "1 file",
                        comment: "Singular metric on the Smart Scan My Clutter card when one large/old file was found."
                    )
                    : String.localizedStringWithFormat(
                        String(
                            localized: "%d files",
                            comment: "Plural metric on the Smart Scan My Clutter card; %d is a count."
                        ),
                        count
                    ))
                : String(
                    localized: "Nothing clutters",
                    comment: "Zero-work metric on the Smart Scan My Clutter card."
                ),
            caption: hasWork
                ? captionWhenWork
                : String(
                    localized: "your downloads",
                    comment: "Zero-work caption on the Smart Scan My Clutter card."
                ),
            selection: hasWork ? tileBinding(.myClutter) : nil,
            checkboxIdentifier: "smartScan.toggleMyClutter",
            reviewIdentifier: hasWork ? "smartScan.reviewMyClutter" : nil,
            onReview: hasWork ? { onRequestReview(.myClutter) } : nil
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
            // Per Open Decision 1: per-module failures don't collapse the
            // whole Run to .failed — they surface here as a warning so the
            // user can see exactly which module's action didn't complete.
            if !summary.failedModules.isEmpty {
                Text(failureLine)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .accessibilityIdentifier("smartScan.doneFailureLine")
            }
            // Maintenance scripts' result line goes below the headline so the
            // user can see what the privileged helper actually did, matching
            // the standalone Optimization screen's output-log idiom.
            if let maintenance = summary.maintenanceOutput {
                Text(maintenance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
                    .accessibilityIdentifier("smartScan.doneMaintenanceOutput")
            }
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

    /// Drop-zero clause assembly so the summary only mentions work that
    /// actually happened. An empty Run lands "Nothing to report" rather than
    /// "0 KB freed · 0 threats removed · …" — which would read as an error.
    /// Exposed `internal` so the view-model-free unit tests in
    /// `SmartScanViewModelTests` can pin the contract without rendering.
    var summaryLine: String {
        var clauses: [String] = []
        if summary.bytesFreed > 0 {
            clauses.append(String.localizedStringWithFormat(
                String(
                    localized: "%@ freed",
                    comment: "Bytes-freed clause of the Smart Scan done summary; %@ is a file-style byte string."
                ),
                smartScanByteFormatter.string(fromByteCount: summary.bytesFreed)
            ))
        }
        if summary.threatsRemoved > 0 {
            clauses.append(String.localizedStringWithFormat(
                String(
                    localized: "%d threats removed",
                    comment: "Threat-count clause of the Smart Scan done summary; %d is a count. Pluralized via Localizable.stringsdict."
                ),
                summary.threatsRemoved
            ))
        }
        if summary.updatesOpened > 0 {
            clauses.append(String.localizedStringWithFormat(
                String(
                    localized: "%d updates opened",
                    comment: "Updates clause of the Smart Scan done summary; %d is a count. Pluralized via Localizable.stringsdict."
                ),
                summary.updatesOpened
            ))
        }
        if summary.clutterFilesRemoved > 0 {
            clauses.append(String.localizedStringWithFormat(
                String(
                    localized: "%@ of clutter removed",
                    comment: "Clutter clause of the Smart Scan done summary; %@ is a file-style byte string."
                ),
                smartScanByteFormatter.string(fromByteCount: summary.clutterBytesRemoved)
            ))
        }
        if summary.maintenanceOutput != nil {
            clauses.append(String(
                localized: "maintenance ran",
                comment: "Maintenance clause of the Smart Scan done summary."
            ))
        }
        if clauses.isEmpty {
            return String(
                localized: "Nothing to report — every selected check was already in good shape.",
                comment: "Smart Scan done summary when Run executed but produced no work (every module's selection drained to empty)."
            )
        }
        return clauses.joined(separator: " · ")
    }

    private var failureLine: String {
        let names = summary.failedModules
            .sorted { String(describing: $0) < String(describing: $1) }
            .map(Self.displayName(for:))
            .joined(separator: ", ")
        return String.localizedStringWithFormat(
            String(
                localized: "Some checks couldn't complete: %@",
                comment: "Warning clause shown below the Smart Scan done summary when one or more modules failed. %@ is a comma-separated list of module names."
            ),
            names
        )
    }

    /// Localized display name for a module — used by `failureLine` so the
    /// warning reads in the UI language, not as the raw case name. The
    /// switch is exhaustive so a future module is a compile-time prompt.
    private static func displayName(for module: SmartScanModule) -> String {
        switch module {
        case .systemJunk:
            return String(localized: "System Junk", comment: "Smart Scan module name in the done-screen failure clause.")
        case .malware:
            return String(localized: "Protection", comment: "Smart Scan module name in the done-screen failure clause.")
        case .optimization:
            return String(localized: "Performance", comment: "Smart Scan module name in the done-screen failure clause.")
        case .applications:
            return String(localized: "Applications", comment: "Smart Scan module name in the done-screen failure clause.")
        case .myClutter:
            return String(localized: "My Clutter", comment: "Smart Scan module name in the done-screen failure clause.")
        }
    }
}
