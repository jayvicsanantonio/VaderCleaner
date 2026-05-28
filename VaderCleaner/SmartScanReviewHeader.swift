// SmartScanReviewHeader.swift
// Shared header row for every Smart Scan Review screen — a left-aligned Back chevron and a centered title.

import SwiftUI

/// Shared header for every Review screen: a left-aligned Back chevron and
/// the screen's title centered. Mirrors the dashboard's "Start Over" top
/// bar so the two surfaces feel like one design. The Back button uses an
/// explicit `HStack(Image, Text)` rather than `Label(_:systemImage:)`
/// because the latter inside `.buttonStyle(.plain)` doesn't reliably
/// surface as a typed `button` element in XCUITest's `app.buttons[…]`
/// query — the plain HStack does.
struct SmartScanReviewHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(String(
                            localized: "Back",
                            comment: "Back button on every Smart Scan Review screen — returns to the results dashboard."
                        ))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("smartScan.review.back")
                .accessibilityLabel(Text(String(
                    localized: "Back",
                    comment: "VoiceOver label for the Back button on Smart Scan Review screens."
                )))
                Spacer()
            }
            Text(title)
                .font(.headline)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}
