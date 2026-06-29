// SpaceLensBottomBar.swift
// Space Lens footer — the boot-volume usage gauge with the removal selection highlighted, the running "N items selected · size" readout, and the Review and Remove button.

import SwiftUI

/// The bar pinned below the bubble chart. On the leading edge: the volume name,
/// "X of Y used", and a thin gauge whose trailing segment shows how much the
/// current removal selection would free. On the trailing edge: the selected
/// count + size and the "Review and Remove" button (disabled with nothing
/// selected).
struct SpaceLensBottomBar: View {

    var viewModel: DiskScannerViewModel

    private static let accent = Color(red: 0.96, green: 0.20, blue: 0.78)

    var body: some View {
        let totals = viewModel.selection.totals
        let usage = viewModel.volumeUsage

        HStack(spacing: 20) {
            volumeGauge(usage: usage, selectedBytes: totals.size)
            Spacer(minLength: 12)
            selectionReadout(count: totals.count, size: totals.size)
            Button {
                viewModel.reviewActive = true
            } label: {
                Text("Review and Remove")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Self.accent)
            .disabled(totals.count == 0)
            .accessibilityIdentifier("space-lens.reviewAndRemove")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Volume gauge

    private func volumeGauge(usage: SpaceLensVolumeUsage, selectedBytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(usage.volumeName.isEmpty ? "Macintosh HD" : usage.volumeName)
                    .font(.callout.weight(.semibold))
                Text(usage.formattedSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("space-lens.volumeUsage")
            }
            GeometryReader { geo in
                let width = geo.size.width
                let usedFrac = usage.usedFraction
                let selFrac = usage.selectionFraction(forSelected: selectedBytes)
                // The selection segment overlaps the trailing end of the used
                // portion to read as "this much of what's used would be freed".
                let selWidth = min(CGFloat(selFrac) * width, CGFloat(usedFrac) * width)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(.white.opacity(0.55))
                        .frame(width: CGFloat(usedFrac) * width)
                    Capsule().fill(Self.accent)
                        .frame(width: selWidth)
                        .offset(x: CGFloat(usedFrac) * width - selWidth)
                }
            }
            .frame(height: 6)
            .frame(maxWidth: 360)
        }
    }

    // MARK: - Selection readout

    private func selectionReadout(count: Int, size: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("\(count.formatted(.number)) Items selected")
                .font(.callout)
                .monospacedDigit()
                .accessibilityIdentifier("space-lens.selectedCount")
            Text("|").foregroundStyle(.tertiary)
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .binary))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
