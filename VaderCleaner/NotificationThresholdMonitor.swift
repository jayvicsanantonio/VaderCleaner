// NotificationThresholdMonitor.swift
// Bridges SystemStatsService readings + PreferencesStore toggles to NotificationDispatching, with a per-kind cooldown to prevent spam.

import Foundation
import Observation

/// Watches `SystemStatsService` and dispatches threshold-based notifications
/// (low disk, high RAM) through a `NotificationDispatching` instance, gated by
/// the user's `PreferencesStore` toggles and a per-kind cooldown.
///
/// Malware and large-files notifications are pushed by feature modules via the
/// `triggerMalwareDetected` / `triggerLargeFilesFound` hooks rather than
/// derived from a polling reading. They use the same toggle + cooldown gate so
/// every notification path goes through one chokepoint and the spam-prevention
/// behavior cannot drift between callers.
///
/// ## Cooldown
///
/// A 5-minute (300 s) per-kind cooldown means a user who is genuinely at
/// 5% free disk space gets at most one banner every five minutes — enough to
/// remind, not enough to harass. The cooldown table is keyed by `Kind` so each
/// notification type has its own clock; a ringing low-disk alert does not
/// suppress a fresh malware alert from the same scan.
///
/// ## Testability
///
/// The clock is injected (`now: () -> Date`) so tests can advance virtual time
/// across the cooldown boundary without sleeping. The dispatcher is protocol-
/// backed so tests can record calls without scheduling real notifications.
@MainActor
@Observable
final class NotificationThresholdMonitor {

    /// Notification kinds that share the cooldown table. Adding a new kind
    /// here requires updating the toggle gate in the `evaluate…` / `trigger…`
    /// path that produces it; the compiler's exhaustiveness check on switches
    /// over `Kind` keeps that honest.
    private enum Kind: Hashable {
        case lowDisk
        case highRAM
        case malware
        case largeFiles
    }

    // MARK: - Dependencies

    @ObservationIgnored private let stats: SystemStatsService
    @ObservationIgnored private let preferences: PreferencesStore
    @ObservationIgnored private let dispatcher: NotificationDispatching
    @ObservationIgnored private let cooldown: TimeInterval
    @ObservationIgnored private let now: () -> Date

    /// Last dispatch timestamp per `Kind`. A missing entry means "never fired",
    /// which the cooldown check treats as "elapsed" so the first eligible
    /// reading after launch always dispatches.
    @ObservationIgnored private var lastFired: [Kind: Date] = [:]

    /// Flips to `true` once `requestPermission()` has resolved (the user
    /// either accepted or denied the system prompt). Until then, threshold
    /// readings are observed but do **not** dispatch and do **not** stamp
    /// the cooldown table — `UNUserNotificationCenter` silently drops
    /// `add(_:)` calls placed before authorization has been requested, so
    /// stamping a 5-minute cooldown against a notification that never
    /// surfaced would suppress the next genuine alert immediately after
    /// the user grants permission.
    @ObservationIgnored private var hasResolvedPermission: Bool

    /// Observation re-arming tasks driving `evaluate(disk:)` / `evaluate(ram:)`
    /// off `SystemStatsService.diskSpace` / `.ramUsage`. Held so they tear
    /// down with `self`; `deinit` cancels each so the recursive
    /// `withObservationTracking` registrations stop re-arming once the
    /// monitor is gone.
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    // MARK: - Init

    /// - Parameters:
    ///   - stats: Source of disk/RAM readings. The monitor subscribes to
    ///     `$diskSpace` and `$ramUsage` and forwards each new value to the
    ///     `evaluate(disk:)` / `evaluate(ram:)` paths below.
    ///   - preferences: Backing store for the notification toggles and
    ///     `diskFreeThresholdGB`.
    ///   - dispatcher: Notification sink. Production passes
    ///     `NotificationManager()`; tests pass a recording stub.
    ///   - cooldown: Per-kind minimum interval between successive dispatches.
    ///     Defaults to 5 minutes per the spec; tests can pass a smaller value
    ///     if they prefer to advance the virtual clock by less.
    ///   - now: Clock provider. Defaults to `Date.init` in production; tests
    ///     pass a closure that reads from a mutable virtual time so cooldown
    ///     tests don't sleep.
    ///   - assumesPermissionResolved: When `true`, the monitor begins in the
    ///     post-permission state and dispatches immediately on the first
    ///     eligible reading. Production defaults to `false` so a threshold
    ///     reading that arrives during the FDA onboarding window (before
    ///     ContentView has called `requestPermission()`) is silently
    ///     observed without burning its cooldown. Tests that want to exercise
    ///     dispatch synchronously pass `true`.
    init(
        stats: SystemStatsService,
        preferences: PreferencesStore,
        dispatcher: NotificationDispatching,
        cooldown: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init,
        assumesPermissionResolved: Bool = false
    ) {
        self.stats = stats
        self.preferences = preferences
        self.dispatcher = dispatcher
        self.cooldown = cooldown
        self.now = now
        self.hasResolvedPermission = assumesPermissionResolved

        // Observation-only delivery (no initial value) is exactly the
        // `.dropFirst()` semantics the old `@Published` subscription enforced
        // by hand: the original initial `DiskStats.empty` / `MemoryStats.empty`
        // readings would otherwise register as "0% free, fire low-disk!" the
        // moment the monitor is constructed. `withObservationTracking`'s
        // `onChange` fires only on actual mutations, so the first real
        // `refresh()` is what wakes each task.
        observationTasks.append(Self.observe(
            { stats.diskSpace },
            handler: { [weak self] disk in self?.evaluate(disk: disk) }
        ))
        observationTasks.append(Self.observe(
            { stats.ramUsage },
            handler: { [weak self] ram in self?.evaluate(ram: ram) }
        ))
    }

    deinit {
        for task in observationTasks {
            task.cancel()
        }
    }

    /// Drives `handler` once for every detected change of `read()`. Bridges the
    /// single-shot `withObservationTracking { … } onChange:` registration into
    /// a continuous stream by re-arming after each emission. Marked `static`
    /// so it doesn't capture `self` — the handler is the only weakly-captured
    /// reference back to the monitor.
    @MainActor
    private static func observe<Value>(
        _ read: @escaping @MainActor () -> Value,
        handler: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                // `onChange` fires synchronously during the mutation's
                // `willSet`, so reading the value there would observe the old
                // value. Resume the continuation without a payload and read
                // afterwards — by then the new value is committed, and we skip
                // the per-change `Task` allocation that would otherwise widen
                // the window where a rapid second mutation goes unobserved.
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = read()
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                handler(read())
            }
        }
    }

    // MARK: - Threshold evaluation (public for testability)

    /// Evaluates a disk-space reading and dispatches a low-disk notification
    /// if all four conditions hold:
    ///   1. Permission has been resolved (see `hasResolvedPermission`).
    ///   2. The user has `notifyLowDisk` enabled.
    ///   3. Free space is strictly below `diskFreeThresholdGB` gigabytes.
    ///   4. The low-disk cooldown has elapsed since the last firing.
    /// `totalBytes == 0` short-circuits to no-op — that is the pre-first-
    /// refresh placeholder and would otherwise compute a 0% free reading.
    func evaluate(disk: DiskStats) {
        guard hasResolvedPermission else { return }
        guard preferences.notifyLowDisk else { return }
        guard disk.totalBytes > 0 else { return }

        let freeBytes = disk.totalBytes > disk.usedBytes
            ? disk.totalBytes - disk.usedBytes
            : 0
        // Decimal GB to match the Finder-style sizes the picker and banner show.
        let thresholdBytes = UInt64(max(0, preferences.diskFreeThresholdGB)) * 1_000_000_000

        guard freeBytes < thresholdBytes else { return }
        guard isCooldownElapsed(.lowDisk) else { return }

        dispatcher.sendLowDiskNotification(freeBytes: Int64(freeBytes))
        lastFired[.lowDisk] = now()
    }

    /// Evaluates a memory-pressure reading and dispatches a high-RAM
    /// notification only when pressure is `.critical`. `.fair` is intentionally
    /// not surfaced — it's a soft yellow state in the Health Monitor, not a
    /// "do something now" alert. Cooldown gates re-firing the same way as
    /// disk.
    func evaluate(ram: MemoryStats) {
        guard hasResolvedPermission else { return }
        guard preferences.notifyHighRAM else { return }
        guard ram.pressureLevel == .critical else { return }
        guard isCooldownElapsed(.highRAM) else { return }

        dispatcher.sendHighRAMNotification(pressureLevel: "Critical")
        lastFired[.highRAM] = now()
    }

    // MARK: - Trigger hooks for feature modules

    /// Called by the malware scanner (Prompt 24) when a threat is detected.
    /// Stub-wired here so the cooldown + toggle gate is in place before the
    /// scanner module exists.
    func triggerMalwareDetected(threatName: String) {
        guard hasResolvedPermission else { return }
        guard preferences.notifyMalwareFound else { return }
        guard isCooldownElapsed(.malware) else { return }

        dispatcher.sendMalwareDetectedNotification(threatName: threatName)
        lastFired[.malware] = now()
    }

    /// Called by the Large & Old Files feature (Prompt 15) once a scan
    /// completes. Stub-wired here so the cooldown + toggle gate is consistent
    /// with the other notification paths.
    func triggerLargeFilesFound(count: Int, totalSize: Int64) {
        guard hasResolvedPermission else { return }
        guard preferences.notifyLargeFilesFound else { return }
        guard isCooldownElapsed(.largeFiles) else { return }

        dispatcher.sendLargeFilesFoundNotification(count: count, totalSize: totalSize)
        lastFired[.largeFiles] = now()
    }

    // MARK: - Permission passthrough

    /// Forwards to the dispatcher's `requestPermission()` and flips the
    /// internal gate so subsequent threshold readings can dispatch. The flag
    /// flips regardless of whether the user accepted or denied — once the
    /// system prompt has been answered, `UNUserNotificationCenter.add` will
    /// either deliver or silently drop, but in neither case is there value in
    /// continuing to suppress at the monitor layer.
    func requestPermission() async {
        await dispatcher.requestPermission()
        hasResolvedPermission = true
    }

    // MARK: - Cooldown helper

    /// Returns true if `kind` has either never fired or fired at least
    /// `cooldown` seconds ago. The boundary is inclusive: a sample exactly
    /// `cooldown` seconds after the previous firing is treated as elapsed, so
    /// a 5-minute cooldown means "next allowed firing is at last + 5 minutes,"
    /// matching what most users would intuit from the spec wording.
    private func isCooldownElapsed(_ kind: Kind) -> Bool {
        guard let last = lastFired[kind] else { return true }
        return now().timeIntervalSince(last) >= cooldown
    }
}
