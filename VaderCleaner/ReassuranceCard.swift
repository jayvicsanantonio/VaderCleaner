// ReassuranceCard.swift
// The shared "all good" dashboard tile used to backfill a section's grid to its minimum count when there aren't enough real findings to fill it.

import SwiftUI

/// A calm, positive dashboard card shown when a section has fewer real findings
/// than the minimum tile count. Shares the glass surface and corner radius of
/// the app's other dashboard cards so a backfilled grid reads as one set.
struct ReassuranceCard: View {
    let content: ReassuranceContent
    let accent: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: content.icon)
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(content.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(content.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recommendation.reassurance.\(content.id)")
    }
}
