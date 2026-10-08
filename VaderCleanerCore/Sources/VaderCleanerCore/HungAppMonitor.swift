// HungAppMonitor.swift
// Best-effort "application not responding" alerts for running apps.

import Foundation
import AppKit
import ApplicationServices

/// A running app the monitor can probe.
struct RunningAppInfo: Equatable {
    let name: String
    let pid: pid_t
}

/// Notifies when a running app stops responding, gated by `notifyHungApps` and a
/// per-process cooldown.
///
/// Responsiveness is best-effort: it probes the app over the Accessibility API
/// with a short messaging timeout and only when the process is Accessibility-
/// trusted (otherwise every app would look hung). Both the app list and the
/// responsiveness probe are injected so the firing logic is unit-testable.
@MainActor
final class HungAppMonitor {

    typealias AppLister = () -> [RunningAppInfo]
    /// `@Sendable` so the probe pass can run on a detached task — each AX
    /// probe can block up to its 0.5s messaging timeout, which on the main
    /// thread read as a repeating micro-hang every poll.
    typealias ResponsivenessProbe = @Sendable (pid_t) -> Bool

    private let preferences: PreferencesStore
    private let dispatcher: NotificationDispatching
    private let appLister: AppLister
    private let isResponsive: ResponsivenessProbe
    private let cooldown: TimeInterval
    private let pollInterval: TimeInterval
    private let now: () -> Date

    private var lastFired: [pid_t: Date] = [:]
    private var timer: Timer?
    /// True while a probe pass is in flight. A pass over many hung apps can
    /// outlast the poll interval (0.5s worst case per app), and an overlapping
    /// pass would double-fire before the first records its cooldowns.
    private var isProbing = false

    init(
        preferences: PreferencesStore,
        dispatcher: NotificationDispatching,
        appLister: @escaping AppLister = { HungAppMonitor.runningApps() },
        isResponsive: @escaping ResponsivenessProbe = { HungAppMonitor.probeResponsive($0) },
        cooldown: TimeInterval = 60 * 60,
        pollInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.dispatcher = dispatcher
        self.appLister = appLister
        self.isResponsive = isResponsive
        self.cooldown = cooldown
        self.pollInterval = pollInterval
        self.now = now
    }

    /// One poll pass: probes each running app exactly once — off the main
    /// actor, since a hung app holds its probe for the full messaging
    /// timeout — then fires for each unresponsive app whose per-process
    /// cooldown has elapsed, and forgets apps that have since recovered or
    /// quit. Overlapping passes are skipped rather than queued.
    func evaluate() async {
        guard preferences.notifyHungApps else { return }
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }

        let apps = appLister()
        let probe = isResponsive
        let responsive: [pid_t: Bool] = await Task.detached(priority: .utility) {
            var result: [pid_t: Bool] = [:]
            for app in apps {
                result[app.pid] = probe(app.pid)
            }
            return result
        }.value

        let livePIDs = Set(apps.map(\.pid))
        for app in apps where responsive[app.pid] == false {
            if let last = lastFired[app.pid], now().timeIntervalSince(last) < cooldown { continue }
            dispatcher.sendHungAppNotification(appName: app.name)
            lastFired[app.pid] = now()
        }
        // Drop bookkeeping for apps that recovered or quit so a future hang
        // alerts again.
        for pid in lastFired.keys where !livePIDs.contains(pid) {
            lastFired[pid] = nil
        }
        for app in apps where responsive[app.pid] == true {
            lastFired[app.pid] = nil
        }
    }

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The user-facing apps currently running (regular activation policy).
    nonisolated static func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { RunningAppInfo(name: $0.localizedName ?? "An app", pid: $0.processIdentifier) }
    }

    /// Best-effort responsiveness probe. Returns `true` (responsive) when the
    /// process can't be probed — no Accessibility trust — so a missing
    /// permission never produces false "not responding" alerts.
    nonisolated static func probeResponsive(_ pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXTitleAttribute as CFString, &value)
        // A hung app fails to answer the message within the timeout window.
        return result != .cannotComplete
    }
}
