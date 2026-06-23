// SystemJunkDashboardSubviews.swift
// Category dashboard, tiles, and per-file review screens for the System Junk section — mirrors the Large & Old Files dashboard so the two sections share one look.

import SwiftUI
import AppKit

// MARK: - Formatting

enum SystemJunkFormatting {
    /// Shared file-size formatter for the dashboard tiles and card titles.
    /// Constructed once because `ByteCountFormatter` allocates measurable
    /// internal state per instance.
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

// MARK: - Dashboard

/// Post-scan landing surface for the Cleanup section: a "Start Over" bar, the
/// section hero, the total-junk headline, and a "Review All Junk" action that
/// opens the Cleanup Manager. Mirrors the Performance dashboard's hero layout so
/// the two sections share one post-scan look.
struct SystemJunkDashboardView: View {
    let totalBytes: Int64
    /// Opens the complete, unfiltered junk file list across every group.
    let onReviewAll: () -> Void
    /// Discards the current scan and returns to the section intro.
    let onStartOver: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            startOverBar
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                Image("systemJunk")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .accessibilityHidden(true)

                Text(headline)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("system-junk.summary")

                Button(action: onReviewAll) {
                    Text(String(
                        localized: "Review All Junk",
                        comment: "Button that opens the complete, unfiltered junk file list across every category."
                    ))
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("system-junk.viewAll")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("system-junk.dashboard")
    }

    /// Top-left "Start Over" control, mirroring the Smart Scan dashboard's bar.
    /// Uses an explicit `HStack(Image, Text)` rather than `Label` so it surfaces
    /// reliably as a button in XCUITest. Keeps the `system-junk.rescan`
    /// identifier the UI tests already target.
    private var startOverBar: some View {
        HStack {
            Button(action: onStartOver) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(String(
                        localized: "Start Over",
                        comment: "Button on the Cleanup results screen that discards the scan and returns to the intro."
                    ))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("system-junk.rescan")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private var headline: String {
        let size = SystemJunkFormatting.byteFormatter.string(fromByteCount: totalBytes)
        let format = String(
            localized: "There are %@ of junk files on your Mac.",
            comment: "Cleanup dashboard headline; %@ is the total reclaimable size."
        )
        return String.localizedStringWithFormat(format, size)
    }
}
