// WelcomeView.swift
// The first-run welcome flow: a full-window tour whose backdrop recolours to each step's section identity, ending in the user's first Smart Scan.

import SwiftUI

/// Covers the whole window on a first launch. Each step adopts a real
/// section's colour identity, so the window gradient the user watches during
/// the tour is the very gradient they will see in Cleanup, in Protection, and
/// in Performance — the flow doubles as a preview of the app.
///
/// The floating Scan disc lives in a child panel above this window, so
/// `ContentView` suppresses it while the flow is up; nothing here can cover it.
struct WelcomeView: View {
    var viewModel: WelcomeViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How often the access step re-probes Full Disk Access. Slow enough to be
    /// free, quick enough that returning from System Settings lands on a
    /// checkmark that is already there.
    private static let accessPollInterval: Duration = .seconds(1.5)

    private var content: WelcomeStepContent { viewModel.step.content }
    private var accent: Color { content.theme.accent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            stepBody
            Spacer(minLength: 24)
            footer
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                // An opaque floor in the incoming step's own gradient, so the
                // flow always covers the window completely.
                //
                // The crossfade above it puts two backdrops at partial opacity
                // at once — around the midpoint each is near 50%, which
                // together cover only ~75% and let the main window's navigation
                // rail show through behind the flow. This layer takes the
                // remaining quarter.
                //
                // It snaps to the new colours rather than fading, which is
                // invisible: at the start of the crossfade the outgoing
                // backdrop is still fully opaque and hides it, and by the time
                // it is exposed the incoming backdrop has faded in over it
                // wearing the very same gradient. Only the blooms crossfade.
                LinearGradient(
                    colors: [content.theme.backdropTop, content.theme.backdropBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // The same backdrop the main window uses, keyed to the step so
                // moving through the flow crossfades the window between section
                // hues instead of cutting between them.
                VaderBackground(theme: content.theme)
                    .id(viewModel.step)
                    .transition(.opacity)
                    .animation(.smooth(duration: 0.55), value: viewModel.step)
            }
            .ignoresSafeArea()
        }
        .vaderShell(accent: accent)
        .animation(.smooth(duration: VaderMotion.surfaceDuration), value: viewModel.step)
        // Re-probe when the user comes back from System Settings, so the
        // access step has already flipped to "granted" on their return.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { viewModel.refreshAccess() }
        }
        // A slow poll while the permission step is showing turns granting
        // access into something the flow notices on its own. Keyed to the step
        // so the loop is torn down the moment the user moves on.
        .task(id: viewModel.step) {
            guard viewModel.step == .access else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.accessPollInterval)
                guard !Task.isCancelled else { return }
                viewModel.refreshAccess()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome")
    }

    // MARK: Header

    /// The app's own icon and name, plus the escape hatch out of the tour.
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

            Text(verbatim: "VaderCleaner")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            Spacer(minLength: 0)

            if viewModel.canSkipTour {
                Button {
                    viewModel.skipTour()
                } label: {
                    Text("Skip tour", comment: "First-run flow: jumps past the capability tour.")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityIdentifier("welcome.skipTour")
                .transition(.opacity)
            }
        }
    }

    // MARK: Step body

    /// Hero on the left, copy on the right — the same composition as a section
    /// intro, so the flow already reads like the app. Keyed to the step so the
    /// two halves exchange together.
    private var stepBody: some View {
        HStack(alignment: .center, spacing: 56) {
            WelcomeHero(content: content, isFinale: viewModel.step == .ready)
                .id(viewModel.step)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))

            WelcomeStepColumn(viewModel: viewModel)
                .id(viewModel.step)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 26)),
                        removal: .opacity
                    )
                )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Footer

    /// Progress rail on the left, the step's actions on the right.
    private var footer: some View {
        HStack(alignment: .center, spacing: 24) {
            WelcomeProgressRail(step: viewModel.step, accent: accent)

            Spacer(minLength: 0)

            if viewModel.canGoBack {
                Button {
                    viewModel.back()
                } label: {
                    Text("Back", comment: "First-run flow: returns to the previous step.")
                }
                .buttonStyle(.vaderGlass)
                .controlSize(.large)
                .accessibilityIdentifier("welcome.back")
                .transition(.opacity)
            }

            primaryActions
        }
    }

    /// The step's forward actions. Every step but the last offers a single
    /// Continue; the permission step adds the System Settings jump beside it,
    /// and the last step replaces Continue with the two hand-offs.
    @ViewBuilder
    private var primaryActions: some View {
        switch viewModel.step {
        case .access:
            HStack(spacing: 12) {
                Button {
                    viewModel.requestFullDiskAccess()
                } label: {
                    Text(
                        "Open System Settings",
                        comment: "First-run flow: opens the Full Disk Access pane."
                    )
                }
                .buttonStyle(viewModel.hasFullDiskAccess ? AnyButtonStyle(.vaderGlass) : AnyButtonStyle(.vaderWhite))
                .controlSize(.large)
                .accessibilityIdentifier("welcome.openSystemSettings")

                Button {
                    viewModel.advance()
                } label: {
                    Text("Continue", comment: "First-run flow: advances to the next step.")
                }
                .buttonStyle(viewModel.hasFullDiskAccess ? AnyButtonStyle(.vaderWhite) : AnyButtonStyle(.vaderGlass))
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("welcome.continue")
            }
        case .ready:
            HStack(spacing: 12) {
                Button {
                    viewModel.finish(startingScan: false)
                } label: {
                    Text(
                        "Explore on my own",
                        comment: "First-run flow: closes the flow without starting a scan."
                    )
                }
                .buttonStyle(.vaderGlass)
                .controlSize(.large)
                .accessibilityIdentifier("welcome.explore")

                Button {
                    viewModel.finish(startingScan: true)
                } label: {
                    Text(
                        "Run First Smart Scan",
                        comment: "First-run flow: closes the flow and starts a Smart Scan."
                    )
                }
                .buttonStyle(.vaderWhite)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("welcome.runFirstScan")
            }
        case .welcome, .clean, .protect, .tune:
            Button {
                viewModel.advance()
            } label: {
                Text(
                    viewModel.step == .welcome
                        ? String(localized: "Get Started", comment: "First-run flow: leaves the greeting step.")
                        : String(localized: "Continue", comment: "First-run flow: advances to the next step.")
                )
            }
            .buttonStyle(.vaderWhite)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("welcome.continue")
        }
    }
}

/// Type-erased button style, so the permission step can swap which of its two
/// buttons wears the bright fill as access is granted without duplicating the
/// whole button declaration in both branches.
struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<Style: ButtonStyle>(_ style: Style) {
        makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}

#Preview {
    WelcomeView(
        viewModel: WelcomeViewModel(
            store: WelcomeStore(defaults: UserDefaults(suiteName: "preview")!),
            fullDiskAccessChecker: { false },
            openSystemSettings: {}
        )
    )
    .frame(width: 1320, height: 720)
}
