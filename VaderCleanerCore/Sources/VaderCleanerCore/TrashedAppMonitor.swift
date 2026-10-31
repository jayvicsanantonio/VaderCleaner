// TrashedAppMonitor.swift
// Offers correct uninstallation when the user drags an app into the Trash.

import Foundation

/// Watches the user's Trash for newly-added `.app` bundles and, when
/// `offerUninstallOnTrash` is on, dispatches a notification offering to remove
/// the app's leftover files too. The Trash listing is injected so the
/// new-app diff is unit-testable without a real Trash directory.
///
/// Listing runs off the main actor: the Trash can hold enough items to take many
/// seconds, which would freeze the window every time it is listed. It is
/// unreadable without Full Disk Access, so that freeze first appears on the
/// launch after the user grants it.
@MainActor
final class TrashedAppMonitor {

    /// Returns the display names of `.app` bundles currently in the Trash.
    typealias AppLister = @Sendable () -> [String]

    private let preferences: PreferencesStore
    private let dispatcher: NotificationDispatching
    private let appLister: AppLister

    /// Apps already seen in the Trash, so only *newly* trashed apps notify.
    private var seen: Set<String> = []
    private var source: DispatchSourceFileSystemObject?
    private var primeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Set when the Trash changes during a listing. A cleanup writes to it
    /// thousands of times, and overlapping listings could finish out of order
    /// and replay apps already seen, so changes wait for one follow-up instead.
    private var needsAnotherPoll = false
    /// Whether the apps already in the Trash have been recorded.
    private(set) var hasPrimedBaseline = false

    init(
        preferences: PreferencesStore,
        dispatcher: NotificationDispatching,
        appLister: @escaping AppLister = { TrashedAppMonitor.listTrashedApps() }
    ) {
        self.preferences = preferences
        self.dispatcher = dispatcher
        self.appLister = appLister
    }

    /// Pure decision: notifies for each app that appears in the Trash for the
    /// first time. When the toggle is off it still advances the baseline so
    /// turning it on later doesn't replay apps trashed in the meantime.
    func evaluate(trashedAppNames: [String]) {
        let current = Set(trashedAppNames)
        defer { seen = current }
        guard preferences.offerUninstallOnTrash else { return }
        for name in current.subtracting(seen).sorted() {
            dispatcher.sendAppTrashedNotification(appName: name)
        }
    }

    func start() {
        stop()
        // Prime the baseline so apps already in the Trash don't notify on launch.
        // Watching starts only once it's in place, so no change can be compared
        // against an empty baseline.
        primeTask = Task { [weak self, appLister] in
            let baseline = await Self.listOffMainActor(using: appLister)
            guard let self, !Task.isCancelled else { return }
            self.seen = Set(baseline)
            self.hasPrimedBaseline = true
            self.watchTrash()
        }
    }

    private func watchTrash() {
        let trash = Self.trashURL()
        let descriptor = open(trash.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Close the descriptor this source owns — captured locally so a
        // stop()/restart closes the right fd rather than a shared field a
        // newer start() may have overwritten.
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        primeTask?.cancel()
        primeTask = nil
        pollTask?.cancel()
        pollTask = nil
        needsAnotherPoll = false
        hasPrimedBaseline = false
        source?.cancel()
        source = nil
    }

    func poll() {
        guard pollTask == nil else {
            needsAnotherPoll = true
            return
        }
        pollTask = Task { [weak self, appLister] in
            let names = await Self.listOffMainActor(using: appLister)
            guard let self, !Task.isCancelled else { return }
            self.evaluate(trashedAppNames: names)
            self.pollTask = nil
            if self.needsAnotherPoll {
                self.needsAnotherPoll = false
                self.poll()
            }
        }
    }

    nonisolated private static func listOffMainActor(using appLister: @escaping AppLister) async -> [String] {
        await Task.detached(priority: .utility) { appLister() }.value
    }

    nonisolated private static func trashURL() -> URL {
        (try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
    }

    /// Production listing: the `.app` bundles at the top level of the Trash.
    nonisolated static func listTrashedApps() -> [String] {
        let trash = trashURL()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "app" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}
