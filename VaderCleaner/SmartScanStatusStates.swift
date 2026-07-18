// SmartScanStatusStates.swift
// Smart Scan's transient full-screen states: the Run-in-progress indicator, the plain-language receipt, and the scan-failed screen.

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
        VStack(spacing: 28) {
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

// MARK: - Receipt

/// The plain-language record of what Run just did: a headline with the total
/// freed, one line per finding with a check or warning glyph, and failures
/// called out in amber with a next step instead of being glossed over.
struct CareReceiptView: View {

    let receipt: CareReceipt
    let onDone: () -> Void
    /// Optional so previews and tests need not inject a store.
    @Environment(CareHistoryStore.self) private var history: CareHistoryStore?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(headline)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("smartScan.doneHeading")
                if receipt.lines.isEmpty {
                    Text(String(
                        localized: "Nothing was selected to fix this time.",
                        comment: "Receipt subtitle when the Run pass had nothing to do."
                    ))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                }
                if let lifetimeLine = history?.lifetimeFreedLine() {
                    Text(lifetimeLine)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .accessibilityIdentifier("smartScan.receiptLifetimeLine")
                }
            }
            if !receipt.lines.isEmpty {
                VStack(spacing: 10) {
                    ForEach(receipt.lines, id: \.kind) { line in
                        CareReceiptLineRow(line: line)
                    }
                }
                .frame(maxWidth: 520)
            }
            Button(String(localized: "Done", comment: "Dismiss button on the Smart Scan receipt."), action: onDone)
                .buttonStyle(.vaderProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("smartScan.doneButton")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartScan.receipt")
    }

    private var headline: String {
        guard receipt.totalBytesFreed > 0 else {
            return String(localized: "All done", comment: "Receipt headline when no bytes were freed.")
        }
        return String.localizedStringWithFormat(
            String(localized: "All done — %@ freed", comment: "Receipt headline with the total bytes freed."),
            CareFindingCopy.formattedBytes(receipt.totalBytesFreed)
        )
    }
}

/// One receipt line: glyph, plain description of what happened, and the
/// per-finding byte credit where one exists.
private struct CareReceiptLineRow: View {

    let line: CareReceiptLine

    var body: some View {
        HStack(spacing: 12) {
            glyph
            Text(text)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(isFailure ? .orange : .white.opacity(0.85))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if line.bytesFreed > 0 {
                Text(CareFindingCopy.formattedBytes(line.bytesFreed))
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vaderTileGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("smartScan.receiptLine.\(line.kind.rawValue)")
    }

    private var isFailure: Bool {
        if case .failed = line.outcome { return true }
        return false
    }

    @ViewBuilder
    private var glyph: some View {
        switch line.outcome {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .green)
        case .partial:
            Image(systemName: "checkmark.circle.badge.questionmark")
                .foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var text: String {
        switch line.outcome {
        case .failed(let message):
            let title = CareFindingCopy.title(for: line.kind)
            return message.isEmpty
                ? String.localizedStringWithFormat(
                    String(localized: "%@ — this step didn't work.", comment: "Receipt line for a failed step without details."),
                    title
                )
                : String.localizedStringWithFormat(
                    String(localized: "%@ — %@", comment: "Receipt line for a failed step: finding title, reason."),
                    title, message
                )
        case .partial(let failedCount):
            return String.localizedStringWithFormat(
                String(
                    localized: "%@ — %d items handled, %d couldn't be.",
                    comment: "Receipt line for a partially-successful step."
                ),
                CareFindingCopy.title(for: line.kind), line.itemsProcessed, failedCount
            )
        case .success:
            return String.localizedStringWithFormat(
                String(localized: "%@ — %d items handled.", comment: "Receipt line for a successful step."),
                CareFindingCopy.title(for: line.kind), line.itemsProcessed
            )
        }
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
