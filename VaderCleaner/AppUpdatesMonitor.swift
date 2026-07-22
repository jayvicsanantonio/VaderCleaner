// AppUpdatesMonitor.swift
// Periodically checks whether the user's apps have newer versions and notifies when the set of available updates changes.

import Foundation

/// Checks once a day whether any installed app has a newer version available
/// and dispatches a notification when that changes, gated by the
/// `notifyAppUpdates` toggle.
///
/// The probe reaches the network once per installed app (App Store lookup or
/// Sparkle appcast), so the toggle gates the *probe*, not just the banner — off
/// means no background network at all. Repeat findings are suppressed: only a
/// change in how many updates are waiting is worth telling the user about
/// again.
@MainActor
final class AppUpdatesMonitor {

    /// Returns how many installed apps have an update available. Production
    /// walks `AppDiscovery` + `UpdateProbe`; tests inject a count.
    typealias UpdateCountProbe = @MainActor () async -> Int

    private enum Key {
        static let lastCheck = "preferences.appUpdates.lastCheckDate"
        static let lastAnnouncedCount = "preferences.appUpdates.lastAnnouncedCount"
    }

    private let preferences: PreferencesStore
    private let dispatcher: NotificationDispatching
    private let probe: UpdateCountProbe
    private let interval: TimeInterval
    private let defaults: UserDefaults
    private let now: () -> Date

    private var timer: Timer?

    init(
        preferences: PreferencesStore,
        dispatcher: NotificationDispatching,
        probe: @escaping UpdateCountProbe = AppUpdatesMonitor.liveProbe,
        interval: TimeInterval = 24 * 60 * 60,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.dispatcher = dispatcher
        self.probe = probe
        self.interval = interval
        self.defaults = defaults
        self.now = now
    }

    /// When the last probe ran. Persisted because `start()` checks immediately
    /// and the app can be launched many times a day — without this, every
    /// launch would hit the network once per installed app.
    private var lastCheck: Date? {
        get { (defaults.object(forKey: Key.lastCheck) as? TimeInterval).map(Date.init(timeIntervalSinceReferenceDate:)) }
        set { defaults.set(newValue?.timeIntervalSinceReferenceDate, forKey: Key.lastCheck) }
    }

    /// The count last announced, so an unchanged result stays quiet. Persisted
    /// so quitting and reopening doesn't re-announce the same updates.
    private var lastAnnouncedCount: Int {
        get { defaults.integer(forKey: Key.lastAnnouncedCount) }
        set { defaults.set(newValue, forKey: Key.lastAnnouncedCount) }
    }

    /// Runs one check. Skips the probe entirely when the toggle is off or one
    /// ran within the last `interval` — the probe is a network call per
    /// installed app, so it needs a real budget rather than a bare timer.
    func check() async {
        guard preferences.notifyAppUpdates else { return }
        if let last = lastCheck, now().timeIntervalSince(last) < interval { return }

        let count = await probe()
        lastCheck = now()

        guard count > 0 else {
            // Everything is current — clear the memo so the next batch of
            // updates is announced rather than suppressed as "same as before".
            lastAnnouncedCount = 0
            return
        }
        guard count != lastAnnouncedCount else { return }

        dispatcher.sendAppUpdatesNotification(count: count)
        lastAnnouncedCount = count
    }

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        self.timer = timer
        Task { await check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Production probe: enumerates installed apps and counts the ones with an
    /// update available. Failures count as zero — a missed check is never worth
    /// surfacing an error for.
    static let liveProbe: UpdateCountProbe = {
        guard let apps = try? await DefaultAppDiscovery().installedApps(includingSystemApps: false) else {
            return 0
        }
        return await UpdateProbe.live().availableUpdates(for: apps).count
    }
}
