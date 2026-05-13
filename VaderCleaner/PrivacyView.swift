// PrivacyView.swift
// Privacy feature view — renders the idle/scanning/preview/clearing/complete states from PrivacyViewModel and binds the per-browser per-category checkboxes plus the system Recent Items toggle and Clear / Re-scan / Scan Again actions.

import SwiftUI

/// Detail view shown when the user selects "Privacy" in the sidebar.
/// Each `PrivacyViewModel.Phase` maps to a dedicated subview, mirroring
/// `SystemJunkView`'s shape:
///   - `.idle` — centered Scan call-to-action.
///   - `.scanning` — progress spinner.
///   - `.preview` — list of detected browsers with disclosure-grouped
///     category checkboxes plus a "Recent Items" toggle, footer with
///     total + Clear + Re-scan.
///   - `.clearing` — progress spinner.
///   - `.complete` — "X freed" summary plus Scan Again.
///   - `.failed` — message plus Try Again.
///
/// Accessibility identifiers are namespaced under `privacy.*` so future
/// UI tests can drive the flow without relying on label localisation.
struct PrivacyView: View {

    @ObservedObject private var viewModel: PrivacyViewModel
    @State private var showClearConfirmation = false

    init(viewModel: PrivacyViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle:
                idleState
            case .scanning:
                progressState(label: "Scanning…", identifier: "privacy.scanning")
            case .preview:
                previewState
            case .clearing:
                progressState(label: "Clearing…", identifier: "privacy.clearing")
            case .complete(let bytes):
                completeState(bytesFreed: bytes)
            case .failed(let stage, let message):
                failedState(stage: stage, message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(NavigationSection.privacy.title)
    }

    // MARK: - States

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Privacy")
                .font(.title2.weight(.semibold))
            Text("Clear browsing history, downloads, cookies, cache, saved form data across detected browsers, and the system Recent Items list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan") {
                Task { await viewModel.preview() }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("privacy.scan")
        }
        .padding()
    }

    private func progressState(label: String, identifier: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityIdentifier(identifier)
    }

    private var previewState: some View {
        VStack(spacing: 0) {
            previewList
            Divider()
            previewFooter
        }
        .alert("Clear selected privacy data?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task { await viewModel.clear() }
            }
        } message: {
            // The Recent Items toggle is independent from the per-browser
            // selections, so the alert text must reflect whichever steps
            // actually run. Naming "Recent Items" when its toggle is off
            // would mislead the user.
            if viewModel.isClearRecentsChecked {
                Text("This permanently removes the selected browser data and the system Recent Items list. Browsers will recreate the storage on next launch but the data won't be recoverable.")
            } else {
                Text("This permanently removes the selected browser data. Browsers will recreate the storage on next launch but the data won't be recoverable.")
            }
        }
    }

    private var previewList: some View {
        List {
            ForEach(viewModel.detectedBrowsers) { browser in
                Section {
                    ForEach(PrivacyCategory.allCases) { category in
                        // Non-actionable categories (e.g. Chromium /
                        // Firefox `.downloads`, which lives inside the
                        // browsing-history SQLite and can't be cleared
                        // independently at the file level) render as a
                        // disabled row with a coupling caption rather
                        // than a checkbox — otherwise the UI would
                        // claim to do something the clearer can't
                        // deliver.
                        if viewModel.isCategoryActionable(browser: browser, category: category) {
                            CategoryRow(
                                category: category,
                                sizeBytes: viewModel.size(for: browser, category: category),
                                isChecked: Binding(
                                    get: { viewModel.isChecked(browser: browser, category: category) },
                                    set: { _ in viewModel.toggle(browser: browser, category: category) }
                                )
                            )
                            .accessibilityIdentifier("privacy.row.\(browser.rawValue).\(category.rawValue)")
                        } else {
                            CoupledCategoryRow(category: category)
                                .accessibilityIdentifier("privacy.row.\(browser.rawValue).\(category.rawValue).coupled")
                        }
                    }
                } header: {
                    BrowserHeader(
                        browser: browser,
                        totalBytes: viewModel.sizeOnDisk(for: browser)
                    )
                }
            }

            Section {
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { viewModel.isClearRecentsChecked },
                        set: { _ in viewModel.toggleClearRecents() }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Recent Items")
                            .font(.body.weight(.medium))
                        Text("Clears the Apple-menu Recent Items list and this app's recent documents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("privacy.row.recentItems")
            } header: {
                Text("System")
                    .font(.callout.weight(.semibold))
            }
        }
    }

    private var previewFooter: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(PrivacyView.byteFormatter.string(fromByteCount: viewModel.totalSelectedSize))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("privacy.totalSelected")
            }
            Spacer()
            Button("Re-scan") {
                viewModel.scanAgain()
            }
            .accessibilityIdentifier("privacy.rescan")
            Button("Clear") {
                showClearConfirmation = true
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.totalSelectedSize == 0 && !viewModel.isClearRecentsChecked)
            .accessibilityIdentifier("privacy.clear")
        }
        .padding(16)
    }

    private func completeState(bytesFreed: Int64) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(PrivacyView.byteFormatter.string(fromByteCount: bytesFreed) + " freed")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("privacy.bytesFreed")
            Text("Browsers may need to be restarted before disk space fully reflects the change.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan Again") {
                viewModel.scanAgain()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("privacy.scanAgain")
        }
        .padding()
    }

    private func failedState(stage: PrivacyViewModel.FailureStage, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(stage == .scanning ? "Couldn't complete the scan" : "Couldn't finish clearing")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("privacy.errorMessage")
            Button("Try Again") {
                viewModel.scanAgain()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("privacy.tryAgain")
        }
        .padding()
    }

    // MARK: - Formatter

    /// Shared byte formatter; same allocation rationale as
    /// `SystemJunkView.byteFormatter`.
    fileprivate static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        return f
    }()
}

// MARK: - Subviews

private struct BrowserHeader: View {
    let browser: Browser
    let totalBytes: Int64

    var body: some View {
        HStack(spacing: 8) {
            Text(browser.displayName)
                .font(.callout.weight(.semibold))
            Spacer()
            Text(PrivacyView.byteFormatter.string(fromByteCount: totalBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Row rendered for categories whose data isn't independently
/// clearable on the surrounding browser — Chromium / Firefox
/// `.downloads` lives inside the same SQLite as `.history`, so a
/// path-based clear of just downloads would also wipe browsing
/// history. The row replaces the checkbox + size with an
/// informational caption explaining the coupling so the UI never
/// presents a control that does nothing.
private struct CoupledCategoryRow: View {
    let category: PrivacyCategory

    var body: some View {
        HStack(spacing: 12) {
            // Spacer matches the checkbox width so the category-name
            // column stays aligned with sibling rows in the same group.
            Spacer().frame(width: 16)
            Text(category.displayName)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Included with Browsing History")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct CategoryRow: View {
    let category: PrivacyCategory
    let sizeBytes: Int64
    @Binding var isChecked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(category.displayName)
                .font(.body)
            Spacer()
            Text(PrivacyView.byteFormatter.string(fromByteCount: sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview("Idle") {
    PrivacyView(viewModel: PrivacyViewModel(
        detector: { [] },
        sizer: { _, _ in 0 },
        pathsFor: { _, _ in [] },
        clearer: { _, _ in },
        clearRecentFiles: { }
    ))
    .frame(width: 700, height: 480)
}
