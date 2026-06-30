// TrashedAppMonitor.swift
// Offers correct uninstallation when the user drags an app into the Trash.

import Foundation

/// Watches the user's Trash for newly-added `.app` bundles and, when
/// `offerUninstallOnTrash` is on, dispatches a notification offering to remove
/// the app's leftover files too. The Trash listing is injected so the
/// new-app diff is unit-testable without a real Trash directory.
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
    private var watchedDescriptor: Int32 = -1

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
        // Prime the baseline so apps already in the Trash don't notify on launch.
        seen = Set(appLister())

        let trash = Self.trashURL()
        let descriptor = open(trash.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watchedDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedDescriptor, fd >= 0 { close(fd) }
            self?.watchedDescriptor = -1
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func poll() {
        evaluate(trashedAppNames: appLister())
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
