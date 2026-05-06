// NotificationThresholdMonitor.swift
// Bridges SystemStatsService readings + PreferencesStore toggles to NotificationDispatching, with a per-kind cooldown to prevent spam.

import Foundation
import Combine

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
final class NotificationThresholdMonitor: ObservableObject {

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

    private let stats: SystemStatsService
    private let preferences: PreferencesStore
    private let dispatcher: NotificationDispatching
    private let cooldown: TimeInterval
    private let now: () -> Date

    /// Last dispatch timestamp per `Kind`. A missing entry means "never fired",
    /// which the cooldown check treats as "elapsed" so the first eligible
    /// reading after launch always dispatches.
    private var lastFired: [Kind: Date] = [:]

    /// Combine subscriptions from `SystemStatsService.$diskSpace` /
    /// `$ramUsage`. Held in `cancellables` so they tear down with `self`.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    /// - Parameters:
    ///   - stats: Source of disk/RAM readings. The monitor subscribes to
    ///     `$diskSpace` and `$ramUsage` and forwards each new value to the
    ///     `evaluate(disk:)` / `evaluate(ram:)` paths below.
    ///   - preferences: Backing store for the four notification toggles and
    ///     `diskSpaceThresholdPercent`.
    ///   - dispatcher: Notification sink. Production passes
    ///     `NotificationManager()`; tests pass a recording stub.
    ///   - cooldown: Per-kind minimum interval between successive dispatches.
    ///     Defaults to 5 minutes per the spec; tests can pass a smaller value
    ///     if they prefer to advance the virtual clock by less.
    ///   - now: Clock provider. Defaults to `Date.init` in production; tests
    ///     pass a closure that reads from a mutable virtual time so cooldown
    ///     tests don't sleep.
    init(
        stats: SystemStatsService,
        preferences: PreferencesStore,
        dispatcher: NotificationDispatching,
        cooldown: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.stats = stats
        self.preferences = preferences
        self.dispatcher = dispatcher
        self.cooldown = cooldown
        self.now = now

        // Drop the first emission from each publisher because `@Published`
        // sends the initial value immediately on subscription. That initial
        // value is `DiskStats.empty` / `MemoryStats.empty` — both at zero —
        // which would falsely register as "0% free, fire low-disk!" the
        // moment the monitor is constructed. After the first real `refresh()`
        // the publishers emit honest readings.
        stats.$diskSpace
            .dropFirst()
            .sink { [weak self] disk in self?.evaluate(disk: disk) }
            .store(in: &cancellables)

        stats.$ramUsage
            .dropFirst()
            .sink { [weak self] ram in self?.evaluate(ram: ram) }
            .store(in: &cancellables)
    }

    // MARK: - Threshold evaluation (public for testability)

    /// Evaluates a disk-space reading and dispatches a low-disk notification
    /// if all three conditions hold:
    ///   1. The user has `notifyLowDisk` enabled.
    ///   2. Free percentage is strictly below `diskSpaceThresholdPercent`.
    ///   3. The low-disk cooldown has elapsed since the last firing.
    /// `totalBytes == 0` short-circuits to no-op — that is the pre-first-
    /// refresh placeholder and would otherwise compute a 0% free reading.
    func evaluate(disk: DiskStats) {
        guard preferences.notifyLowDisk else { return }
        guard disk.totalBytes > 0 else { return }

        let freeBytes = disk.totalBytes > disk.usedBytes
            ? disk.totalBytes - disk.usedBytes
            : 0
        let freePercent = Double(freeBytes) / Double(disk.totalBytes) * 100.0

        guard freePercent < preferences.diskSpaceThresholdPercent else { return }
        guard isCooldownElapsed(.lowDisk) else { return }

        dispatcher.sendLowDiskNotification(freePercent: freePercent)
        lastFired[.lowDisk] = now()
    }

    /// Evaluates a memory-pressure reading and dispatches a high-RAM
    /// notification only when pressure is `.critical`. `.fair` is intentionally
    /// not surfaced — it's a soft yellow state in the Health Monitor, not a
    /// "do something now" alert. Cooldown gates re-firing the same way as
    /// disk.
    func evaluate(ram: MemoryStats) {
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
        guard preferences.notifyMalwareFound else { return }
        guard isCooldownElapsed(.malware) else { return }

        dispatcher.sendMalwareDetectedNotification(threatName: threatName)
        lastFired[.malware] = now()
    }

    /// Called by the Large & Old Files feature (Prompt 15) once a scan
    /// completes. Stub-wired here so the cooldown + toggle gate is consistent
    /// with the other notification paths.
    func triggerLargeFilesFound(count: Int, totalSize: Int64) {
        guard preferences.notifyLargeFilesFound else { return }
        guard isCooldownElapsed(.largeFiles) else { return }

        dispatcher.sendLargeFilesFoundNotification(count: count, totalSize: totalSize)
        lastFired[.largeFiles] = now()
    }

    // MARK: - Cooldown helper

    /// Returns true if `kind` has either never fired or fired at least
    /// `cooldown` seconds ago. The boundary is exclusive — a sample exactly
    /// `cooldown` seconds after the previous firing is treated as elapsed,
    /// matching test expectations (301 s after, not 300 s).
    private func isCooldownElapsed(_ kind: Kind) -> Bool {
        guard let last = lastFired[kind] else { return true }
        return now().timeIntervalSince(last) > cooldown
    }
}
