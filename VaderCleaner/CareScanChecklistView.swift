// CareScanChecklistView.swift
// The scanning experience: a live checklist of the six care domains, each row filling in with a plain-language result the moment its sub-scans genuinely finish.

import SwiftUI

/// Replaces a staged one-at-a-time hero with an honest concurrent checklist:
/// rows never reorder, every domain shows what it is doing right now, and
/// results land as they truly complete — including grey "Skipped" and amber
/// "Couldn't check" so a problem never hides behind an all-clear.
struct CareScanChecklistView: View {

    var viewModel: SmartScanViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 28) {
            header
            // One container so the six glass rows resolve in a single pass.
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(viewModel.checklistDomains, id: \.self) { domain in
                        CareChecklistRow(domain: domain, status: viewModel.domainStatus(domain))
                    }
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : VaderMotion.surface,
            value: viewModel.checklistDomains.map { viewModel.domainStatus($0) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.scanning")
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(String(localized: "Checking your Mac…", comment: "Scanning checklist headline."))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            if viewModel.scannedItemCount > 0 {
                Text(String.localizedStringWithFormat(
                    String(
                        localized: "Looked at %d items so far",
                        comment: "Scanning checklist running total of items examined."
                    ),
                    viewModel.scannedItemCount
                ))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityIdentifier("smartScan.scanning.detail")
            } else {
                Text(String(
                    localized: "This runs in the background — feel free to keep working.",
                    comment: "Scanning checklist reassurance line before counts arrive."
                ))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

/// One domain's checklist row: status glyph, domain name, and a live line
/// that moves from waiting → activity → plain-language result.
private struct CareChecklistRow: View {

    let domain: CareDomain
    let status: SmartScanViewModel.DomainStatus

    var body: some View {
        HStack(spacing: 14) {
            statusGlyph
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detailLine)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(detailColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vaderTileGlass()
        .opacity(status == .skipped ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("smartScan.scanning.row.\(domain.rawValue)")
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch status {
        case .pending:
            Circle()
                .strokeBorder(.white.opacity(0.25), lineWidth: 1.5)
                .frame(width: 18, height: 18)
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white, .green)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    private var detailLine: String {
        switch status {
        case .pending:
            return String(localized: "Waiting…", comment: "Checklist row line before its domain starts.")
        case .running(let items):
            guard items > 0 else {
                return String(localized: "Checking…", comment: "Checklist row line while its domain scans.")
            }
            return String.localizedStringWithFormat(
                String(localized: "Checking… %d items", comment: "Checklist row line with a live item count."),
                items
            )
        case .finished(let line):
            return line
        case .skipped:
            return String(localized: "Skipped — not included in your scan settings.", comment: "Checklist row line for a domain excluded in settings.")
        case .failed:
            return String(localized: "Couldn't check — we'll still show everything else.", comment: "Checklist row line when a domain's scan failed.")
        }
    }

    private var detailColor: Color {
        switch status {
        case .failed: return .orange
        case .finished: return .white.opacity(0.8)
        default: return .white.opacity(0.55)
        }
    }
}
