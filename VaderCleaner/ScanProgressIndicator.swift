// ScanProgressIndicator.swift
// A section-tinted animated scan indicator — a glowing core with sonar pulses and counter-rotating arcs — used in place of the plain system spinner on every scan/clean-in-progress screen.

import SwiftUI

/// Animated, section-tinted stand-in for `ProgressView` on the app's
/// scan/clean-in-progress screens. A soft accent bloom, three expanding "sonar"
/// pulses, two counter-rotating gradient arcs, and a pulsing core read as an
/// active scan in the app's glow language — giving the in-progress state
/// personality without leaving the section's palette.
///
/// The tint defaults to the active section accent from the environment (set by
/// `vaderShell`), so each section's loader matches its window backdrop with no
/// per-call wiring. Honors Reduce Motion: the spin and sonar drop to a calm,
/// static glowing emblem.
struct ScanProgressIndicator: View {
    /// Overall diameter; every element scales from this.
    var size: CGFloat = 132
    /// Explicit tint override. `nil` uses the active section accent so the
    /// loader matches the backdrop it sits on.
    var accent: Color? = nil

    @Environment(\.sectionAccent) private var sectionAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    private var tint: Color { accent ?? sectionAccent }

    var body: some View {
        ZStack {
            bloom
            if !reduceMotion { sonar }
            arcs
            core
        }
        .frame(width: size, height: size)
        .onAppear { animating = true }
        // The adjacent status label carries the meaning; the art is decorative.
        .accessibilityHidden(true)
    }

    /// Soft accent halo that breathes behind the rest.
    private var bloom: some View {
        Circle()
            .fill(tint.opacity(0.30))
            .blur(radius: size * 0.22)
            .scaleEffect(animating ? 1.05 : 0.8)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                value: animating
            )
    }

    /// Three rings that expand out of the core and fade, staggered so a new
    /// pulse leaves as the last one dissolves — the "scanning" read.
    private var sonar: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(tint.opacity(0.45), lineWidth: 1.5)
                    .scaleEffect(animating ? 1.0 : 0.25)
                    .opacity(animating ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 2.6)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.85),
                        value: animating
                    )
            }
        }
    }

    /// Two trimmed gradient arcs at different radii, spinning in opposite
    /// directions so the indicator reads as active machinery.
    private var arcs: some View {
        ZStack {
            arc(trim: 0.62, lineWidth: 4, inset: 0, clockwise: true, duration: 1.4)
            arc(trim: 0.40, lineWidth: 3, inset: size * 0.16, clockwise: false, duration: 2.0)
        }
    }

    private func arc(trim: CGFloat, lineWidth: CGFloat, inset: CGFloat, clockwise: Bool, duration: Double) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [tint.opacity(0), tint]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .padding(inset)
            .rotationEffect(.degrees(animating ? (clockwise ? 360 : -360) : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: duration).repeatForever(autoreverses: false),
                value: animating
            )
    }

    /// Glowing core that pulses at the centre.
    private var core: some View {
        Circle()
            .fill(tint)
            .frame(width: size * 0.12, height: size * 0.12)
            .shadow(color: tint.opacity(0.9), radius: size * 0.07)
            .scaleEffect(animating ? 1.18 : 0.85)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: animating
            )
    }
}

/// The status text beneath the scan indicator. Rotates through a set of short,
/// playful, section-flavored phrases (one phrase → static) so the wait has
/// personality, with the live count shown beneath in the section accent. The
/// count keeps its own accessibility identifier; the rotating phrase is
/// combined into one announcement for assistive tech. Honors Reduce Motion by
/// holding on the first phrase.
struct ScanningStatusView: View {
    /// Preformatted live count, e.g. "12,431 items". `nil` omits the line.
    private let count: String?
    /// Accessibility identifier for the count line (preserved for UI tests).
    private let countIdentifier: String?

    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The phrases shuffled once when the view is first built, so each scan
    /// starts on a different line and runs through them in a different order.
    /// `@State(initialValue:)` keeps the shuffle stable for the life of one
    /// scan (later re-inits from count updates reuse this storage).
    @State private var order: [String]
    @State private var index = 0

    init(phrases: [String], count: String? = nil, countIdentifier: String? = nil) {
        self.count = count
        self.countIdentifier = countIdentifier
        _order = State(initialValue: phrases.shuffled())
    }

    private var phrase: String {
        order.isEmpty ? "" : order[index % order.count]
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Text(phrase)
                    .id(phrase)
                    .transition(.opacity)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            .animation(.smooth(duration: 0.5), value: phrase)

            if let count {
                Text(count)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier(countIdentifier ?? "")
            }
        }
        .task(id: order.count) {
            guard !reduceMotion, order.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                index += 1
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Short, playful, section-flavored status lines shown while a scan runs. Kept
/// in one place so every section's loader has consistent voice. The switch is
/// exhaustive so a new section is a compile-time prompt to give it a voice.
enum ScanPhrases {
    static func scanning(for section: NavigationSection) -> [String] {
        switch section {
        case .smartScan:
            return [
                "Casting a wide net…", "Rounding up every module…",
                "Leaving no stone unturned…", "Doing the full rounds…",
                "Checking under the hood…", "Lining up the whole crew…",
                "Running the full playbook…", "Sweeping every corner at once…",
                "Putting your Mac through its paces…", "Tag-teaming every scanner…",
                "Giving everything a once-over…", "Coordinating the cleanup squad…",
                "Firing on all cylinders…", "Taking the grand tour…",
                "Looking high and low…",
            ]
        case .systemJunk:
            return [
                "Rooting through the caches…", "Shaking out the logs…",
                "Sweeping up the crumbs…", "Emptying the junk drawer…",
                "Dusting off forgotten temp files…", "Wrangling stray cache files…",
                "Clearing the cobwebs…", "Bagging up the digital litter…",
                "Scrubbing the nooks and crannies…", "Rounding up the leftovers…",
                "Decluttering behind the scenes…", "Tidying the system shelves…",
                "Chasing down stale caches…", "Raking up the loose ends…",
                "Taking out the trash…",
            ]
        case .largeOldFiles:
            return [
                "Hunting for space hogs…", "Digging up forgotten files…",
                "Weighing the heavy hitters…", "Following the dust trails…",
                "Sizing up the giants…", "Unearthing ancient downloads…",
                "Tracking down the big ones…", "Sifting through the archives…",
                "Spotting the storage bullies…", "Measuring the heavyweights…",
                "Finding what time forgot…", "Rummaging through old folders…",
                "Flushing out the hoarders…", "Peeking into dusty corners…",
                "Counting the calories on disk…",
            ]
        case .malwareRemoval:
            return [
                "Sniffing out bad actors…", "Checking every nook…",
                "Matching against signatures…", "Standing guard…",
                "Inspecting the suspects…", "Frisking incoming files…",
                "Hunting for digital pests…", "Cross-checking the watchlist…",
                "Shining a light in dark corners…", "Keeping the gremlins out…",
                "Scanning for troublemakers…", "Patrolling the perimeter…",
                "Reading the rap sheets…", "Sweeping for booby traps…",
                "Holding the line…",
            ]
        case .spaceLens:
            return [
                "Mapping your disk…", "Measuring every folder…",
                "Charting the territory…", "Sizing things up…",
                "Surveying the landscape…", "Drawing the storage map…",
                "Tallying up the folders…", "Plotting the big blocks…",
                "Exploring the disk frontier…", "Counting every nook of storage…",
                "Building the bird's-eye view…", "Tracing the directory tree…",
                "Pacing out the territory…", "Sketching the layout…",
                "Following every branch…",
            ]
        case .performance, .applications, .healthMonitor:
            return generic
        }
    }

    /// Phrase set for the active Smart Scan stage, so the rotating status
    /// follows whatever sub-scan is currently running rather than always
    /// reading the broad "Casting a wide net…" voice. The broad file sweep
    /// reuses the Smart Scan voice (it genuinely is the all-modules phase); the
    /// malware content scan borrows the Malware Removal voice; and the
    /// app-update probe gets its own dedicated set.
    static func smartScanStage(_ stage: SmartScanStage) -> [String] {
        switch stage {
        case .sweepingFiles:
            return scanning(for: .smartScan)
        case .scanningThreats:
            return scanning(for: .malwareRemoval)
        case .checkingApps:
            return checkingApps
        }
    }

    /// App-update-flavored voice for the Smart Scan stage that probes installed
    /// apps for newer versions. Kept distinct from the generic set so the
    /// network-bound check that outlasts the file walks reads as deliberate
    /// work, not a stalled spinner.
    static let checkingApps = [
        "Knocking on every app's door…", "Asking apps for their latest…",
        "Checking the app shelves…", "Lining up the update queue…",
        "Polling for fresher versions…", "Pinging the update feeds…",
        "Seeing who's fallen behind…", "Comparing version numbers…",
        "Rounding up the stragglers…", "Looking for newer builds…",
        "Chasing down the latest releases…", "Taking app attendance…",
        "Scouting for upgrades…", "Reading the release notes…",
        "Tallying who needs a refresh…",
    ]

    /// Fallback voice for sections without a bespoke set.
    static let generic = [
        "Working through it…", "Crunching the numbers…",
        "Almost there…", "Hang tight…",
        "Tightening the bolts…", "Running the diagnostics…",
        "Sorting it all out…", "Checking the gauges…",
        "Doing the heavy lifting…", "Just a moment…",
        "Warming up the engines…", "Putting things in order…",
    ]
}

#Preview {
    VStack(spacing: 24) {
        ScanProgressIndicator(accent: Color(red: 0.78, green: 0.25, blue: 0.98))
        ScanningStatusView(
            phrases: ScanPhrases.scanning(for: .systemJunk),
            count: "12,431 items"
        )
    }
    .frame(width: 320, height: 360)
    .environment(\.sectionAccent, Color(red: 0.13, green: 0.90, blue: 0.21))
    .background(Color.black)
}
