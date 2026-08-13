// SectionPrewarmQueue.swift
// Runs the section scans a finished Smart Scan kicks off back to back rather than all at once, so the prewarm can't contend with the UI or itself for CPU and memory.

import Foundation

/// Sequencer for the background scans that populate the standalone sections
/// after a Smart Scan completes.
///
/// Those sections are prewarmed so the user never has to scan one by hand, but
/// each of them fans its own work out concurrently — Large & Old Files runs
/// four scanners, Applications five, Space Lens walks the whole volume. Firing
/// them together put a dozen filesystem walks in flight in the same tick, which
/// is measurably worse than useless: the CPU contention and the peak memory of
/// overlapping results land exactly when the user is reading the Smart Scan
/// results they just waited for. Run one at a time, the same work finishes
/// without stealing the foreground.
///
/// Each step is re-checked immediately before it runs rather than when the
/// sequence is built, so a section the user scanned by hand in the meantime is
/// left alone.
@MainActor
final class SectionPrewarmQueue {

    /// One section's prewarm.
    struct Step {

        /// Whether the section still needs prewarming. Consulted just before
        /// the step runs, so it reflects anything the user did while the queue
        /// was busy with an earlier section.
        let isPending: @MainActor () -> Bool

        /// The section's scan. Awaited to completion before the next step
        /// starts.
        let run: @MainActor () async -> Void

        init(
            isPending: @escaping @MainActor () -> Bool,
            run: @escaping @MainActor () async -> Void
        ) {
            self.isPending = isPending
            self.run = run
        }
    }

    /// Guards against a second Smart Scan completion starting a competing
    /// sequence — the sequence already in flight re-checks every section as it
    /// reaches it, so it covers whatever the newer one would have.
    private var isDraining = false

    private let activity: ScanActivityAssertion

    init(activity: ScanActivityAssertion = ScanActivityAssertion()) {
        self.activity = activity
    }

    /// Runs `steps` in the background. Returns immediately.
    func start(_ steps: [Step]) {
        Task { await self.drain(steps) }
    }

    /// Runs each still-pending step to completion, one at a time, under a
    /// single activity assertion so an idle system sleep can't suspend the
    /// prewarm partway through.
    func drain(_ steps: [Step]) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        await activity(reason: "VaderCleaner is preparing the other sections") {
            for step in steps where step.isPending() {
                await step.run()
            }
        }
    }
}
