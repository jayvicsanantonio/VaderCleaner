// RunConfirmationSheet.swift
// The lightweight confirmation shown when the Fix disc is tapped and the run includes a permanent delete — it lists what will happen and flags the one irreversible step before anything runs.

import SwiftUI

/// A modal card over the results feed that confirms a Run pass which would
/// permanently delete junk. It appears only for that irreversible case (runs
/// with only Trash-safe work skip it), so it stays a one-glance check rather
/// than a dialog on every Fix. Lists each action in feed order and marks the
/// permanent one, then offers Cancel or Fix.
struct RunConfirmationSheet: View {
    let itemCount: Int
    let lines: [SmartScanViewModel.RunActionLine]
    let accent: Color
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var title: String {
        itemCount == 1
            ? String(localized: "Fix 1 item?", comment: "Run confirmation title for a single included finding.")
            : String.localizedStringWithFormat(
                String(localized: "Fix %d items?", comment: "Run confirmation title: number of included findings."),
                itemCount
            )
    }

    var body: some View {
        ZStack {
            // A dim scrim over the feed; tapping it is the same as Cancel.
            Rectangle()
                .fill(.black.opacity(0.45))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)

            card
        }
        .accessibilityIdentifier("smartScan.runConfirmation")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines) { line in
                    RunConfirmationRow(line: line)
                }
            }

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(String(localized: "Cancel", comment: "Run confirmation dismiss button."))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RunConfirmationButtonStyle(kind: .secondary, accent: accent))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("smartScan.cancelRun")

                Button(action: onConfirm) {
                    Text(String(localized: "Fix", comment: "Run confirmation confirm button."))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RunConfirmationButtonStyle(kind: .primary, accent: accent))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("smartScan.confirmRun")
            }
        }
        .padding(20)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.vaderSpaceBlack.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        )
        .padding(24)
    }
}

/// One action line: a dot, the description, and — for the permanent junk
/// delete — a warm tint and a "Permanent" tag so the irreversible step reads
/// at a glance.
private struct RunConfirmationRow: View {
    let line: SmartScanViewModel.RunActionLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(line.isPermanent ? Color.orange : .white.opacity(0.4))
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }

            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(line.isPermanent ? Color.orange : .white.opacity(0.82))

            if line.isPermanent {
                Text(String(localized: "Permanent", comment: "Tag marking the irreversible run action."))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.16)))
            }

            Spacer(minLength: 0)
        }
    }
}

/// The sheet's two buttons: an accent-filled Fix and a quiet bordered Cancel,
/// both capsule-shaped with press feedback.
private struct RunConfirmationButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(kind == .primary ? .white : .white.opacity(0.85))
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(kind == .primary ? accent.deepenedForWhite : Color.white.opacity(0.08))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(kind == .primary ? 0 : 0.16), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

#Preview("Confirmation") {
    RunConfirmationSheet(
        itemCount: 4,
        lines: [
            .init(kind: .junkCleanup, text: "Permanently removes 110.11 GB of junk", isPermanent: true),
            .init(kind: .duplicates, text: "Moves 12 duplicate copies to the Trash", isPermanent: false),
            .init(kind: .appUpdates, text: "Opens 2 app updates", isPermanent: false),
            .init(kind: .maintenanceDue, text: "Runs 3 maintenance tasks", isPermanent: false),
        ],
        accent: Color(red: 0.55, green: 0.36, blue: 0.96),
        onConfirm: {},
        onCancel: {}
    )
    .frame(width: 640, height: 420)
    .background(Color.vaderSpaceBlack)
    .preferredColorScheme(.dark)
}
